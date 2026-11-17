defmodule ExFattureincloud.TestSupport.OpenAPIMock do
  @moduledoc """
  Offline HTTP expectations generated from the vendored OpenAPI, independently
  of the SDK's generated operation catalogue. OpenApiSpex validates the actual
  request and every mocked response; validation never changes the wire payload.

  `examples: true` uses an official media example when present and reports an
  invalid example instead of repairing it. `examples: false` generates a fresh
  value with `OpenApiSpex.Schema.example/2`, excluding example annotations from
  the generation copy only. The original validation schema stays unchanged.
  Generation selects a non-null enum candidate when the schema disallows null.
  `example_issues/0` audits all official JSON media examples explicitly.
  """

  alias OpenApiSpex.Cast.Error, as: CastError
  alias OpenApiSpex.{OpenApi, Reference, Schema}
  alias Plug.Conn

  @official_path Path.expand("../../priv/openapi.json", __DIR__)
  @extensions_path Path.expand("../../priv/openapi-extensions.json", __DIR__)
  @external_resource @official_path
  @external_resource @extensions_path
  @cache_key {__MODULE__, :contract}
  @on_load :load_contract
  @parsers Plug.Parsers.init(parsers: [:json, :multipart], json_decoder: Jason)

  @doc false
  @spec load_contract() :: :ok
  def load_contract do
    raw = @official_path |> File.read!() |> Jason.decode!()
    extensions = @extensions_path |> File.read!() |> Jason.decode!()
    combined = Map.update!(raw, "paths", &Map.merge(&1, extensions["paths"]))

    operations =
      for {path, item} <- combined["paths"],
          {method, operation} <- item,
          method in ~w(get post put patch delete),
          into: %{} do
        {operation["operationId"],
         %{
           id: operation["operationId"],
           method: String.to_existing_atom(method),
           path: path,
           raw: operation,
           inherited_parameters: Map.get(item, "parameters", []),
           extension?: Map.has_key?(extensions["paths"], path)
         }}
      end

    lookup = Map.new(operations, fn {id, _} -> {Macro.underscore(id), id} end)

    :persistent_term.put(@cache_key, %{
      raw: raw,
      extensions: extensions,
      combined: combined,
      spec: OpenApi.from_map(combined),
      operations: operations,
      lookup: lookup
    })

    :ok
  end

  @spec contract() :: map()
  defp contract, do: :persistent_term.get(@cache_key)

  @doc "The untouched official contract, excluding the separately identified extensions."
  @spec raw_contract() :: map()
  def raw_contract, do: contract().raw

  @doc "Decoded official contract together with documented extensions."
  @spec spec() :: OpenApi.t()
  def spec, do: contract().spec

  @doc "All official operation IDs plus the explicitly documented extensions."
  @spec operation_ids() :: [String.t()]
  def operation_ids, do: contract().operations |> Map.keys() |> Enum.sort()

  @doc "Contract descriptor, including resolved parameters and extension provenance."
  @spec operation(atom() | String.t()) :: map()
  def operation(id) do
    id = to_string(id)
    descriptor = Map.fetch!(contract().operations, Map.get(contract().lookup, id, id))

    parameters =
      (descriptor.inherited_parameters ++ Map.get(descriptor.raw, "parameters", []))
      |> Enum.map(&resolve_raw/1)
      |> Map.new(&{{&1["in"], &1["name"]}, &1})
      |> Map.values()

    Map.put(descriptor, :parameters, parameters)
  end

  @doc "Registers a Req.Test expectation validating real HTTP bytes and schema-valid responses."
  @spec expect(term(), atom() | String.t(), keyword()) :: term()
  def expect(name, id, options \\ []) do
    operation = operation(id)
    status = Keyword.get_lazy(options, :status, fn -> default_status(operation) end)

    response =
      Keyword.get_lazy(options, :response, fn -> response_example(id, status, options) end)

    media = response_media(operation, status)
    validate_response!(operation, status, response, media)

    Req.Test.expect(name, Keyword.get(options, :count, 1), fn conn ->
      conn = validate_request!(operation, conn)
      if callback = options[:on_request], do: callback.(conn)
      respond(conn, status, response, media)
    end)
  end

  @doc "Creates required path/query values and a JSON or Req multipart body from the contract."
  @spec request_example(atom() | String.t(), keyword()) :: map()
  def request_example(id, options \\ []) do
    operation = operation(id)
    path_params = parameter_examples(operation, "path")
    query = parameter_examples(operation, "query")
    media = request_media(operation)
    body = media_example(media, options)
    if media, do: validate_value!(body, media.schema, :write, "#{operation.id} request example")

    %{
      method: operation.method,
      path: render_path(operation.path, path_params),
      path_params: path_params,
      query: query,
      body: encode_request_body(body, media),
      content_type: media && media.type,
      source: example_source(media, options),
      extension?: operation.extension?
    }
  end

  @doc "Returns a validated official response example or an independently generated schema example."
  @spec response_example(atom() | String.t(), integer() | nil, keyword()) :: term()
  def response_example(id, status \\ nil, options \\ []) do
    operation = operation(id)
    status = status || default_status(operation)
    media = response_media(operation, status)
    response = media_example(media, options)
    validate_response!(operation, status, response, media)
    response
  end

  @doc "Reports official JSON media examples which contradict their unmodified validation schemas."
  @spec example_issues() :: [map()]
  def example_issues do
    (collect_examples(raw_contract(), [], "priv/openapi.json") ++
       collect_examples(contract().extensions, [], "priv/openapi-extensions.json"))
    |> Enum.uniq_by(&{&1.source_file, &1.source})
    |> Enum.flat_map(fn example ->
      try do
        validate_value!(example.value, example.schema, example.scope, "official example")
        []
      rescue
        error in ExUnit.AssertionError ->
          [example |> Map.drop([:schema, :value, :scope]) |> Map.put(:error, error.message)]
      end
    end)
    |> Enum.sort_by(&{&1.source_file, &1.source})
  end

  @spec validate_request!(map(), Conn.t()) :: Conn.t()
  defp validate_request!(operation, conn) do
    ensure!(
      conn.method == String.upcase(to_string(operation.method)),
      "#{operation.id}: unexpected HTTP method"
    )

    path_params = match_path!(operation, conn.request_path)

    ensure!(
      authorized?(operation, conn),
      "#{operation.id}: missing or invalid Bearer authorization"
    )

    conn = %{conn | path_params: path_params} |> Plug.Parsers.call(@parsers)
    decoded = decoded_operation(operation)

    case OpenApiSpex.cast_and_validate(spec(), decoded, conn, nil,
           replace_params: false,
           apply_defaults: false,
           read_write_scope: :write
         ) do
      {:ok, validated} ->
        if content_type(conn) == "application/json" do
          strict_wire_types!(
            conn.body_params,
            OpenApiSpex.body_params(validated),
            "#{operation.id} JSON request"
          )
        end

        validated

      {:error, errors} ->
        fail!("#{operation.id} request: #{format_errors(errors)}")
    end
  end

  @spec decoded_operation(map()) :: OpenApiSpex.Operation.t()
  defp decoded_operation(operation) do
    item = Map.fetch!(spec().paths, operation.path)
    decoded = Map.fetch!(item, operation.method)
    %{decoded | parameters: (item.parameters || []) ++ (decoded.parameters || [])}
  end

  @spec validate_response!(map(), integer(), term(), map() | nil) :: :ok
  defp validate_response!(operation, status, response, nil) do
    ensure!(
      response in [nil, ""],
      "#{operation.id} HTTP #{status}: response has no declared body"
    )
  end

  defp validate_response!(operation, status, response, media) do
    validate_value!(response, media.schema, :read, "#{operation.id} HTTP #{status} response")
  end

  @spec validate_value!(term(), Schema.t(), :read | :write, String.t()) :: :ok
  defp validate_value!(value, schema, scope, label) do
    case OpenApiSpex.cast_value(value, schema, spec(),
           apply_defaults: false,
           read_write_scope: scope
         ) do
      {:ok, cast} -> strict_wire_types!(value, cast, label)
      {:error, errors} -> fail!("#{label}: #{format_errors(errors)}")
    end
  end

  @spec strict_wire_types!(term(), term(), String.t()) :: :ok
  defp strict_wire_types!(value, cast, label) do
    case wire_mismatch(value, cast, []) do
      nil -> :ok
      path -> fail!("#{label}: #{pointer(path)}: JSON wire types differ after schema casting")
    end
  end

  @spec wire_mismatch(term(), term(), [String.t()]) :: [String.t()] | nil
  defp wire_mismatch(value, %Date{}, _) when is_binary(value), do: nil
  defp wire_mismatch(value, %DateTime{}, _) when is_binary(value), do: nil
  defp wire_mismatch(%Plug.Upload{}, %Plug.Upload{}, _), do: nil
  defp wire_mismatch(nil, nil, _), do: nil
  defp wire_mismatch(left, right, _) when is_boolean(left) and is_boolean(right), do: nil
  defp wire_mismatch(left, right, _) when is_number(left) and is_number(right), do: nil
  defp wire_mismatch(left, right, _) when is_binary(left) and is_binary(right), do: nil

  defp wire_mismatch(left, right, path)
       when is_list(left) and is_list(right) and length(left) == length(right) do
    left
    |> Enum.zip(right)
    |> Enum.with_index()
    |> Enum.find_value(fn {{l, r}, index} ->
      wire_mismatch(l, r, path ++ [to_string(index)])
    end)
  end

  defp wire_mismatch(left, right, path) when is_map(left) and is_map(right) do
    right = Map.new(right, fn {key, value} -> {to_string(key), value} end)

    Enum.find_value(left, fn {key, value} ->
      nested_path = path ++ [to_string(key)]

      if Map.has_key?(right, to_string(key)),
        do: wire_mismatch(value, right[to_string(key)], nested_path),
        else: nested_path
    end)
  end

  defp wire_mismatch(_, _, path), do: path

  @spec parameter_examples(map(), String.t()) :: map()
  defp parameter_examples(operation, location) do
    decoded_operation(operation).parameters
    |> Enum.map(&resolve_parameter/1)
    |> Enum.filter(&(to_string(&1.in) == location and &1.required))
    |> Map.new(fn parameter ->
      schema = parameter.schema
      example = parameter.example || Schema.example(schema, spec())

      example =
        if location == "path" and example in [nil, "", 0], do: path_default(schema), else: example

      {:ok, cast} = OpenApiSpex.cast_value(example, schema, spec(), apply_defaults: false)
      {to_string(parameter.name), cast}
    end)
  end

  @spec resolve_parameter(OpenApiSpex.Parameter.t() | Reference.t()) :: OpenApiSpex.Parameter.t()
  defp resolve_parameter(%Reference{} = reference),
    do: Reference.resolve_parameter(reference, spec().components.parameters)

  defp resolve_parameter(parameter), do: parameter

  @spec path_default(Schema.t()) :: integer() | String.t()
  defp path_default(%Schema{type: :integer}), do: 1
  defp path_default(_), do: "mock-id"

  @spec request_media(map()) :: map() | nil
  defp request_media(operation) do
    decoded = decoded_operation(operation)
    body = resolve_request_body(decoded.requestBody)
    media_descriptor(body && body.content)
  end

  @spec response_media(map(), integer()) :: map() | nil
  defp response_media(operation, status) do
    decoded = decoded_operation(operation)

    response =
      Map.get(decoded.responses || %{}, to_string(status)) ||
        Map.get(decoded.responses || %{}, status)

    ensure!(
      not is_nil(response),
      "#{operation.id}: HTTP #{status} has no documented response schema"
    )

    response =
      case response do
        %Reference{} -> Reference.resolve_response(response, spec().components.responses)
        other -> other
      end

    media_descriptor(response.content)
  end

  @spec media_descriptor(map() | nil) :: map() | nil
  defp media_descriptor(content) when content in [nil, %{}], do: nil

  defp media_descriptor(content) do
    type =
      if Map.has_key?(content, "application/json"),
        do: "application/json",
        else: content |> Map.keys() |> Enum.sort() |> hd()

    %{
      type: type,
      schema: content[type].schema,
      example: content[type].example,
      examples: content[type].examples || %{}
    }
  end

  @spec media_example(map() | nil, keyword()) :: term()
  defp media_example(nil, _), do: nil

  defp media_example(media, options) do
    if example_source(media, options) == :official_example do
      media.example || media.examples |> Enum.sort() |> hd() |> elem(1) |> Map.fetch!(:value)
    else
      media.schema |> without_examples() |> Schema.example(spec()) |> json_value()
    end
  end

  @spec example_source(map() | nil, keyword()) :: :none | :official_example | :schema
  defp example_source(nil, _), do: :none

  defp example_source(media, options) do
    if Keyword.get(options, :examples, true) and
         (not is_nil(media.example) or map_size(media.examples) > 0),
       do: :official_example,
       else: :schema
  end

  @spec without_examples(term()) :: term()
  defp without_examples(%Schema{} = schema) do
    schema
    |> Map.from_struct()
    |> Map.new(fn {key, value} ->
      generated =
        cond do
          key in [:example, :examples] ->
            nil

          key == :enum and is_list(value) and schema.nullable != true ->
            Enum.sort_by(value, &is_nil/1)

          true ->
            without_examples(value)
        end

      {key, generated}
    end)
    |> then(&struct!(Schema, &1))
  end

  defp without_examples(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {key, without_examples(item)} end)

  defp without_examples(value) when is_list(value), do: Enum.map(value, &without_examples/1)
  defp without_examples(value), do: value

  @spec encode_request_body(term(), map() | nil) :: term()
  defp encode_request_body(body, %{type: "multipart/form-data"}) do
    Enum.map(body, fn
      {"attachment", bytes} ->
        {:attachment,
         {bytes, filename: "attachment.bin", content_type: "application/octet-stream"}}

      {key, value} ->
        {key, value}
    end)
  end

  defp encode_request_body(body, _), do: body

  @spec resolve_request_body(term()) :: term()
  defp resolve_request_body(%Reference{} = reference),
    do: Reference.resolve_request_body(reference, spec().components.requestBodies)

  defp resolve_request_body(body), do: body

  @spec default_status(map()) :: integer()
  defp default_status(operation) do
    operation.raw
    |> Map.get("responses", %{})
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "2"))
    |> Enum.sort()
    |> case do
      [status | _] -> String.to_integer(status)
      [] -> fail!("#{operation.id}: no success response is documented")
    end
  end

  @spec render_path(String.t(), map()) :: String.t()
  defp render_path(template, parameters) do
    Enum.reduce(parameters, template, fn {key, value}, path ->
      String.replace(
        path,
        "{" <> key <> "}",
        URI.encode(to_string(value), &URI.char_unreserved?/1)
      )
    end)
  end

  @spec match_path!(map(), String.t()) :: map()
  defp match_path!(operation, actual) do
    segments = String.split(operation.path, "/")
    names = for "{" <> name <- segments, do: String.trim_trailing(name, "}")

    pattern =
      Enum.map_join(segments, "/", fn segment ->
        if String.starts_with?(segment, "{"), do: "([^/]+)", else: Regex.escape(segment)
      end)

    case Regex.run(Regex.compile!("\\A" <> pattern <> "\\z"), actual, capture: :all_but_first) do
      nil ->
        fail!("#{operation.id}: unexpected request path #{actual}; expected #{operation.path}")

      values ->
        Map.new(Enum.zip(names, Enum.map(values, &URI.decode/1)))
    end
  end

  @spec valid_bearer?(Conn.t()) :: boolean()
  defp valid_bearer?(conn) do
    case Conn.get_req_header(conn, "authorization") do
      [value] -> Regex.match?(~r/\ABearer [^\s]+\z/i, value)
      _ -> false
    end
  end

  @spec authorized?(map(), Conn.t()) :: boolean()
  defp authorized?(operation, conn) do
    security = Map.get(operation.raw, "security", raw_contract()["security"]) || []
    security == [] or %{} in security or valid_bearer?(conn)
  end

  @spec content_type(Conn.t()) :: String.t() | nil
  defp content_type(conn) do
    case Conn.get_req_header(conn, "content-type") do
      [type] -> type |> String.split(";", parts: 2) |> hd()
      _ -> nil
    end
  end

  @spec respond(Conn.t(), integer(), term(), map() | nil) :: Conn.t()
  defp respond(conn, status, _body, nil), do: Conn.resp(conn, status, "")

  defp respond(conn, status, body, %{type: "application/json"}),
    do: conn |> Conn.put_status(status) |> Req.Test.json(body)

  defp respond(conn, status, body, media),
    do: conn |> Conn.put_resp_content_type(media.type) |> Conn.resp(status, body)

  @spec resolve_raw(map()) :: map()
  defp resolve_raw(%{"$ref" => reference}) do
    contract().combined
    |> get_in(reference |> String.trim_leading("#/") |> String.split("/"))
    |> resolve_raw()
  end

  defp resolve_raw(value), do: value

  @spec json_value(term()) :: term()
  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  @spec format_errors([OpenApiSpex.Cast.Error.t()]) :: String.t()
  defp format_errors(errors),
    do: Enum.map_join(errors, "; ", &CastError.message_with_path/1)

  @spec ensure!(boolean(), String.t()) :: :ok
  defp ensure!(true, _), do: :ok
  defp ensure!(false, message), do: fail!(message)

  @spec fail!(String.t()) :: no_return()
  defp fail!(message), do: raise(ExUnit.AssertionError, message: message)

  @spec collect_examples(term(), [String.t()], String.t()) :: [map()]
  defp collect_examples(value, path, source_file) when is_map(value) do
    current =
      if List.last(path) == "application/json" and Map.has_key?(value, "schema") do
        schema = decoded_at(path ++ ["schema"])
        scope = if "requestBody" in path, do: :write, else: :read
        examples = value["examples"] || %{}

        examples =
          if Map.has_key?(value, "example"),
            do: Map.put(examples, "$media", %{"value" => value["example"]}),
            else: examples

        for {name, example} <- examples, Map.has_key?(example, "value") do
          example_descriptor(name, example, path, source_file, schema, scope)
        end
      else
        []
      end

    current ++
      Enum.flat_map(value, fn {key, nested} ->
        collect_examples(nested, path ++ [key], source_file)
      end)
  end

  defp collect_examples(value, path, file) when is_list(value),
    do:
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {nested, index} ->
        collect_examples(nested, path ++ [to_string(index)], file)
      end)

  defp collect_examples(_, _, _), do: []

  @spec example_descriptor(String.t(), map(), [String.t()], String.t(), Schema.t(), atom()) ::
          map()
  defp example_descriptor(name, example, path, source_file, schema, scope) do
    suffix = if name == "$media", do: ["example"], else: ["examples", name]

    %{
      operation_id: operation_id_at(path),
      phase: if(scope == :write, do: :request, else: :response),
      status: nil,
      example: name,
      source_file: source_file,
      source: pointer(path ++ suffix),
      schema: schema,
      value: example["value"],
      scope: scope
    }
  end

  @spec operation_id_at([String.t()]) :: String.t() | nil
  defp operation_id_at(["paths", path, method | _]),
    do: get_in(contract().combined, ["paths", path, method, "operationId"])

  defp operation_id_at(_), do: nil

  @spec decoded_at([String.t()]) :: term()
  defp decoded_at(path) do
    Enum.reduce(path, spec(), fn
      key, value when is_list(value) ->
        Enum.at(value, String.to_integer(key))

      key, value ->
        value
        |> Map.to_list()
        |> Enum.find(fn {existing, _} -> to_string(existing) == key end)
        |> elem(1)
    end)
  end

  @spec pointer([String.t()]) :: String.t()
  defp pointer(path),
    do:
      "#/" <>
        Enum.map_join(path, "/", &(&1 |> String.replace("~", "~0") |> String.replace("/", "~1")))
end
