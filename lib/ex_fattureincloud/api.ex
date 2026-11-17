defmodule ExFattureincloud.API do
  @moduledoc """
  Operation dispatcher using the pinned official OpenAPI contract.

  Resource modules call this dispatcher. It checks path parameters, required query
  parameters, enum values and numeric bounds before sending a request. Body maps
  retain the official envelope (usually `%{data: %{...}}`) and are sent as supplied;
  business rules and nested body validation belong to the API.

      ExFattureincloud.call(client, :list_issued_documents,
        path: [company_id: 123], query: [type: "invoice", per_page: 50])

  `Operations.all/0` exposes the complete generated operation catalogue.
  """
  alias ExFattureincloud.{Error, Operations, Transport}

  @spec call(ExFattureincloud.Client.t(), atom() | String.t(), keyword()) ::
          ExFattureincloud.Response.result()
  def call(client, operation, options \\ []) do
    with {:ok, spec} <- fetch_operation(operation),
         :ok <- known_options(options),
         {:ok, path} <- build_path(spec, Keyword.get(options, :path, [])),
         {:ok, query} <- validate_query(spec, Keyword.get(options, :query, [])),
         :ok <- validate_body(spec, options) do
      request_options =
        [query: query, operation: spec.id, accept: spec.accept] ++
          Keyword.take(options, [:body, :multipart])

      Transport.request(client, spec.method, path, request_options)
    end
  end

  defp fetch_operation(operation) do
    case Operations.get(operation) do
      nil -> {:error, Error.validation("unknown API operation")}
      spec -> {:ok, spec}
    end
  end

  defp known_options(options) do
    if Keyword.keys(options) -- [:path, :query, :body, :multipart] == [],
      do: :ok,
      else: {:error, Error.validation("unknown operation option")}
  end

  defp build_path(spec, params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)
    extra = Map.keys(params) -- spec.path_params

    if extra != [] do
      {:error, Error.validation("unknown path parameters: #{Enum.join(extra, ", ")}")}
    else
      Enum.reduce_while(spec.path_params, {:ok, spec.path}, fn name, {:ok, path} ->
        case params[name] do
          value
          when (is_integer(value) and value > 0) or
                 (is_binary(value) and value != "" and value not in [".", ".."]) ->
            encoded = URI.encode(to_string(value), &URI.char_unreserved?/1)
            {:cont, {:ok, String.replace(path, "{" <> name <> "}", encoded)}}

          _ ->
            {:halt, {:error, Error.validation("missing or invalid path parameter: #{name}")}}
        end
      end)
    end
  end

  defp validate_query(spec, params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), normalize(value)} end)
    allowed = Enum.map(spec.query, & &1.name)
    unknown = Map.keys(params) -- allowed

    if unknown != [] do
      {:error, Error.validation("unknown query parameters: #{Enum.join(unknown, ", ")}")}
    else
      Enum.reduce_while(spec.query, {:ok, params}, fn param, acc ->
        case validate_param(param, params[param.name]) do
          :ok -> {:cont, acc}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Map.reject(values, fn {_, value} -> is_nil(value) end)}
        error -> error
      end
    end
  end

  defp normalize(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp normalize(value), do: value

  defp validate_param(param, value) do
    cond do
      is_nil(value) and param.required ->
        invalid(param.name, "is required")

      is_nil(value) ->
        :ok

      param.enum != [] and value not in param.enum ->
        invalid(param.name, "has an unsupported value")

      param.type == "integer" and not is_integer(value) ->
        invalid(param.name, "must be an integer")

      param.type == "boolean" and not is_boolean(value) ->
        invalid(param.name, "must be a boolean")

      param.type == "string" and not is_binary(value) ->
        invalid(param.name, "must be a string")

      is_number(value) and is_number(param.minimum) and value < param.minimum ->
        invalid(param.name, "is below its minimum")

      is_number(value) and is_number(param.maximum) and value > param.maximum ->
        invalid(param.name, "exceeds its maximum")

      true ->
        :ok
    end
  end

  defp invalid(name, reason), do: {:error, Error.validation("query parameter #{name} #{reason}")}

  defp validate_body(spec, options) do
    cond do
      spec.body_required and not Keyword.has_key?(options, :body) and
          not Keyword.has_key?(options, :multipart) ->
        {:error, Error.validation("request body is required")}

      Keyword.has_key?(options, :body) and Keyword.has_key?(options, :multipart) ->
        {:error, Error.validation("body and multipart are mutually exclusive")}

      Keyword.has_key?(options, :multipart) and spec.body != :multipart ->
        {:error, Error.validation("operation does not accept multipart")}

      Keyword.has_key?(options, :body) and spec.body != :json ->
        {:error, Error.validation("operation does not accept JSON")}

      true ->
        :ok
    end
  end
end
