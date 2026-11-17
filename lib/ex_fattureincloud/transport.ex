defmodule ExFattureincloud.Transport do
  @moduledoc false
  alias ExFattureincloud.{Client, Error, Response}
  @methods [:get, :head, :post, :put, :patch, :delete, :options]

  @doc false
  @spec request(Client.t(), atom(), String.t(), keyword()) :: Response.result()
  def request(%Client{} = client, method, path, options \\ []) do
    with :ok <- validate_request(method, path, options) do
      metadata = %{operation: Keyword.get(options, :operation, :custom), method: method}
      attempt(client, method, path, options, metadata, 0)
    end
  end

  @spec validate_request(atom(), term(), keyword()) :: :ok | {:error, Error.t()}
  defp validate_request(method, _path, _options) when method not in @methods,
    do: {:error, Error.validation("unsupported HTTP method")}

  defp validate_request(_method, path, _options) when not is_binary(path),
    do: {:error, Error.validation("path must be API-relative")}

  defp validate_request(_method, path, options) do
    with :ok <- validate_path(path), :ok <- validate_option_names(options) do
      validate_encoding(Keyword.has_key?(options, :body), Keyword.has_key?(options, :multipart))
    end
  end

  @spec validate_path(String.t()) :: :ok | {:error, Error.t()}
  defp validate_path("//" <> _path), do: invalid_path()

  defp validate_path("/" <> _rest = path) do
    if String.contains?(path, ["\\", "?", "#", "\r", "\n"]), do: invalid_path(), else: :ok
  end

  defp validate_path(_path), do: invalid_path()

  @spec invalid_path() :: {:error, Error.t()}
  defp invalid_path,
    do: {:error, Error.validation("path must be API-relative, without query or fragment")}

  @spec validate_option_names(keyword()) :: :ok | {:error, Error.t()}
  defp validate_option_names(options) do
    case Keyword.keys(options) -- [:query, :body, :multipart, :authenticated, :operation, :accept] do
      [] -> :ok
      _unknown -> {:error, Error.validation("unknown request option")}
    end
  end

  @spec validate_encoding(boolean(), boolean()) :: :ok | {:error, Error.t()}
  defp validate_encoding(true, true),
    do: {:error, Error.validation("body and multipart are mutually exclusive")}

  defp validate_encoding(_body?, _multipart?), do: :ok

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
    token |> resolve_token() |> token_authorization()
  rescue
    exception ->
      {:error,
       %Error{kind: :authentication, message: "access token provider failed", cause: exception}}
  catch
    kind, reason ->
      {:error,
       %Error{
         kind: :authentication,
         message: "access token provider failed",
         cause: {kind, reason}
       }}
  end

  @spec resolve_token(term()) :: term()
  defp resolve_token(provider) when is_function(provider, 0), do: provider.()
  defp resolve_token(token), do: token

  @spec token_authorization(term()) :: {:ok, term()} | {:error, Error.t()}
  defp token_authorization({:ok, token}), do: token_authorization(token)

  defp token_authorization(token) when is_binary(token) and token != "",
    do: {:ok, {:bearer, token}}

  defp token_authorization({:error, %Error{kind: :authentication} = error}), do: {:error, error}

  defp token_authorization({:error, %Error{} = error}),
    do:
      {:error,
       %Error{kind: :authentication, message: "access token provider failed", cause: error}}

  defp token_authorization(_token),
    do: {:error, %Error{kind: :authentication, message: "a nonempty access token is required"}}

  defp retry_delay(client, method, {:error, error}, count)
       when method in [:get, :head] and count < client.max_retries do
    base = min(client.max_retry_delay, client.retry_delay * Integer.pow(2, min(count, 20)))

    delay =
      if is_integer(error.retry_after),
        do: error.retry_after * 1_000,
        else:
          min(
            client.max_retry_delay,
            base + if(base > 0, do: :rand.uniform(max(1, div(base, 4))), else: 0)
          )

    if retryable?(error) and delay <= client.max_retry_delay, do: {:retry, delay}, else: :stop
  end

  defp retry_delay(_, _, _, _), do: :stop

  @spec retryable?(Error.t()) :: boolean()
  defp retryable?(%Error{kind: :transport}), do: true

  defp retryable?(%Error{kind: :http, status: status})
       when status in [408, 429, 500, 502, 503, 504], do: true

  defp retryable?(%Error{kind: :http, status: 403, retry_after: seconds})
       when is_integer(seconds), do: true

  defp retryable?(_error), do: false
end
