defmodule ExFattureincloud.Transport do
  @moduledoc false
  alias ExFattureincloud.{Client, Error, Response}
  @methods [:get, :head, :post, :put, :patch, :delete, :options]

  def request(%Client{} = client, method, path, options \\ []) do
    with :ok <- validate_request(method, path, options) do
      metadata = %{operation: Keyword.get(options, :operation, :custom), method: method}
      attempt(client, method, path, options, metadata, 0)
    end
  end

  defp validate_request(method, path, options) do
    cond do
      method not in @methods ->
        {:error, Error.validation("unsupported HTTP method")}

      not is_binary(path) ->
        {:error, Error.validation("path must be API-relative")}

      not String.starts_with?(path, "/") or String.starts_with?(path, "//") or
          String.contains?(path, ["\\", "?", "#", "\r", "\n"]) ->
        {:error, Error.validation("path must be API-relative, without query or fragment")}

      Keyword.keys(options) -- [:query, :body, :multipart, :authenticated, :operation, :accept] !=
          [] ->
        {:error, Error.validation("unknown request option")}

      Keyword.has_key?(options, :body) and Keyword.has_key?(options, :multipart) ->
        {:error, Error.validation("body and multipart are mutually exclusive")}

      true ->
        :ok
    end
  end

  defp attempt(client, method, path, options, metadata, count) do
    started = System.monotonic_time()

    :telemetry.execute(
      [:ex_fattureincloud, :request, :start],
      %{system_time: System.system_time()},
      Map.put(metadata, :attempt, count)
    )

    result = send_request(client, method, path, options)

    status =
      case result do
        {:ok, response} -> response.status
        {:error, error} -> error.status
      end

    :telemetry.execute(
      [:ex_fattureincloud, :request, :stop],
      %{duration: System.monotonic_time() - started},
      Map.merge(metadata, %{attempt: count, status: status, outcome: elem(result, 0)})
    )

    case retry_delay(client, method, result, count) do
      {:retry, delay} ->
        :telemetry.execute(
          [:ex_fattureincloud, :request, :retry],
          %{delay: delay},
          Map.merge(metadata, %{attempt: count, status: status})
        )

        Process.sleep(delay)
        attempt(client, method, path, options, metadata, count + 1)

      :stop ->
        result
    end
  end

  defp send_request(client, method, path, options) do
    with {:ok, auth} <- authorization(client, Keyword.get(options, :authenticated, true)) do
      request_options = [
        method: method,
        url: client.base_url <> path,
        receive_timeout: client.receive_timeout,
        retry: false,
        redirect: false,
        decode_body: false,
        auth: auth,
        headers: [
          {"accept", Keyword.get(options, :accept, "application/json")},
          {"user-agent", client.user_agent}
        ],
        params: Keyword.get(options, :query, [])
      ]

      request_options =
        cond do
          Keyword.has_key?(options, :multipart) ->
            Keyword.put(request_options, :form_multipart, options[:multipart])

          Keyword.has_key?(options, :body) and not is_nil(options[:body]) ->
            Keyword.put(request_options, :json, options[:body])

          true ->
            request_options
        end

      # Set invariants after user-supplied transport options; Req must not replay writes.
      req =
        Req.new(client.req_options)
        |> Req.merge(request_options)
        |> Req.Request.delete_header("authorization")

      case Req.request(req) do
        {:ok, %Req.Response{} = response} ->
          normalize_response(response)

        {:error, cause} ->
          {:error, %Error{kind: :transport, message: "HTTP transport failed", cause: cause}}
      end
    end
  rescue
    exception in File.Error ->
      {:error,
       %Error{kind: :validation, message: "attachment could not be read", cause: exception}}

    exception in Jason.EncodeError ->
      {:error,
       %Error{
         kind: :validation,
         message: "request body could not be JSON encoded",
         cause: exception
       }}
  end

  defp normalize_response(response) do
    case decode_response(response) do
      {:ok, decoded} when decoded.status in 200..299 ->
        {:ok, Response.from_req(decoded)}

      {:ok, decoded} ->
        {:error, Error.from_req(decoded)}

      {:error, cause} when response.status in 200..299 ->
        {:error,
         %Error{
           kind: :protocol,
           status: response.status,
           body: response.body,
           headers: response.headers,
           message: "invalid JSON response",
           cause: cause
         }}

      {:error, _} ->
        {:error, Error.from_req(response)}
    end
  end

  defp decode_response(%{body: body} = response) when is_binary(body) and body != "" do
    type =
      response
      |> Req.Response.get_header("content-type")
      |> List.first("")
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    if type in ["application/json", "text/json"] or String.ends_with?(type, "+json") do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, %{response | body: decoded}}
        {:error, error} -> {:error, error}
      end
    else
      {:ok, response}
    end
  end

  defp decode_response(response), do: {:ok, response}

  defp authorization(_, false), do: {:ok, nil}

  defp authorization(%Client{token: token}, true) do
    value = if is_function(token, 0), do: token.(), else: token

    if is_binary(value) and value != "" do
      {:ok, {:bearer, value}}
    else
      {:error, %Error{kind: :authentication, message: "a nonempty access token is required"}}
    end
  rescue
    exception ->
      {:error,
       %Error{kind: :authentication, message: "access token provider failed", cause: exception}}
  end

  defp retry_delay(client, method, {:error, error}, count)
       when method in [:get, :head] and count < client.max_retries do
    retryable =
      error.kind == :transport or error.status in [408, 429, 500, 502, 503, 504] or
        (error.status == 403 and not is_nil(error.retry_after))

    base = min(client.max_retry_delay, client.retry_delay * Integer.pow(2, min(count, 20)))

    delay =
      if is_integer(error.retry_after),
        do: error.retry_after * 1_000,
        else:
          min(
            client.max_retry_delay,
            base + if(base > 0, do: :rand.uniform(max(1, div(base, 4))), else: 0)
          )

    if retryable and delay <= client.max_retry_delay, do: {:retry, delay}, else: :stop
  end

  defp retry_delay(_, _, _, _), do: :stop
end
