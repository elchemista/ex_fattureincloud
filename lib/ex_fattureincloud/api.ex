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

  @doc "Validates an operation's parameters against the pinned contract and sends its request."
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

    with :ok <- known_parameters(params, spec.path_params, "path") do
      Enum.reduce_while(spec.path_params, {:ok, spec.path}, &put_path_parameter(&1, &2, params))
    end
  end

  defp put_path_parameter(name, {:ok, path}, params) do
    case encode_path_value(params[name]) do
      {:ok, encoded} ->
        {:cont, {:ok, String.replace(path, "{" <> name <> "}", encoded)}}

      :error ->
        {:halt, {:error, Error.validation("missing or invalid path parameter: #{name}")}}
    end
  end

  defp encode_path_value(value) when is_integer(value) and value > 0,
    do: {:ok, Integer.to_string(value)}

  defp encode_path_value(value) when is_binary(value) and value not in ["", ".", ".."],
    do: {:ok, URI.encode(value, &URI.char_unreserved?/1)}

  defp encode_path_value(_value), do: :error

  defp validate_query(spec, params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), normalize(value)} end)
    allowed = Enum.map(spec.query, & &1.name)

    with :ok <- known_parameters(params, allowed, "query"),
         :ok <- validate_query_parameters(spec.query, params) do
      {:ok, Map.reject(params, fn {_key, value} -> is_nil(value) end)}
    end
  end

  defp known_parameters(params, allowed, kind) do
    case Map.keys(params) -- allowed do
      [] ->
        :ok

      unknown ->
        {:error, Error.validation("unknown #{kind} parameters: #{Enum.join(unknown, ", ")}")}
    end
  end

  defp validate_query_parameters(parameters, values) do
    Enum.reduce_while(parameters, :ok, fn parameter, :ok ->
      parameter
      |> validate_param(values[parameter.name])
      |> continue_validation()
    end)
  end

  defp continue_validation(:ok), do: {:cont, :ok}
  defp continue_validation({:error, _error} = result), do: {:halt, result}

  defp normalize(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp normalize(value), do: value

  defp validate_param(%{required: true, name: name}, nil), do: invalid(name, "is required")
  defp validate_param(_parameter, nil), do: :ok

  defp validate_param(parameter, value) do
    with :ok <- validate_enum(parameter, value),
         :ok <- validate_type(parameter, value),
         :ok <- validate_minimum(parameter, value) do
      validate_maximum(parameter, value)
    end
  end

  defp validate_enum(%{enum: []}, _value), do: :ok

  defp validate_enum(%{enum: values, name: name}, value) do
    if value in values, do: :ok, else: invalid(name, "has an unsupported value")
  end

  defp validate_type(%{type: "integer", name: name}, value) when not is_integer(value),
    do: invalid(name, "must be an integer")

  defp validate_type(%{type: "boolean", name: name}, value) when not is_boolean(value),
    do: invalid(name, "must be a boolean")

  defp validate_type(%{type: "string", name: name}, value) when not is_binary(value),
    do: invalid(name, "must be a string")

  defp validate_type(_parameter, _value), do: :ok

  defp validate_minimum(%{minimum: minimum, name: name}, value)
       when is_number(value) and is_number(minimum) and value < minimum,
       do: invalid(name, "is below its minimum")

  defp validate_minimum(_parameter, _value), do: :ok

  defp validate_maximum(%{maximum: maximum, name: name}, value)
       when is_number(value) and is_number(maximum) and value > maximum,
       do: invalid(name, "exceeds its maximum")

  defp validate_maximum(_parameter, _value), do: :ok

  defp invalid(name, reason), do: {:error, Error.validation("query parameter #{name} #{reason}")}

  defp validate_body(spec, options) do
    validate_body_options(
      spec,
      Keyword.has_key?(options, :body),
      Keyword.has_key?(options, :multipart)
    )
  end

  defp validate_body_options(%{body_required: true}, false, false),
    do: {:error, Error.validation("request body is required")}

  defp validate_body_options(_spec, true, true),
    do: {:error, Error.validation("body and multipart are mutually exclusive")}

  defp validate_body_options(%{body: :multipart}, false, true), do: :ok

  defp validate_body_options(_spec, false, true),
    do: {:error, Error.validation("operation does not accept multipart")}

  defp validate_body_options(%{body: :json}, true, false), do: :ok

  defp validate_body_options(_spec, true, false),
    do: {:error, Error.validation("operation does not accept JSON")}

  defp validate_body_options(_spec, false, false), do: :ok
end
