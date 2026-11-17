defmodule ExFattureincloud.ContractTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias ExFattureincloud.{Error, Operations}
  alias ExFattureincloud.TestSupport.OpenAPIMock

  @moduletag :contract

  @specification "priv/openapi.json" |> File.read!() |> Jason.decode!()
  @extensions "priv/openapi-extensions.json" |> File.read!() |> Jason.decode!()
  @paths Map.merge(@specification["paths"], @extensions["paths"])
  @operations for {path, item} <- @paths,
                  {method, operation} <- item,
                  method in ~w(get post put patch delete),
                  do: {path, method, operation["operationId"]}

  setup do
    %{
      client:
        ExFattureincloud.new(
          token: "contract-token",
          max_retries: 0,
          req_options: [plug: {Req.Test, __MODULE__}]
        )
    }
  end

  test "catalogue exactly covers the pinned specification and documented extensions" do
    assert length(Operations.all()) == length(@operations)
    expected = MapSet.new(@operations, fn {_, _, id} -> id end)
    assert MapSet.new(Operations.all(), & &1.operation_id) == expected
    assert MapSet.new(OpenAPIMock.operation_ids()) == expected
  end

  test "the vendored contract matches its recorded hash" do
    metadata = "priv/openapi-source.json" |> File.read!() |> Jason.decode!()
    actual = :crypto.hash(:sha256, File.read!("priv/openapi.json")) |> Base.encode16(case: :lower)
    assert actual == metadata["json_sha256"]
    assert @specification["info"]["version"] == metadata["version"]
  end

  test "upstream example inconsistencies are explicit and cannot silently grow" do
    baseline = "test/fixtures/openapi_example_issues.json" |> File.read!() |> Jason.decode!()
    metadata = "priv/openapi-source.json" |> File.read!() |> Jason.decode!()
    actual = OpenAPIMock.example_issues() |> Jason.encode!() |> Jason.decode!()

    assert baseline["contract_sha256"] == metadata["json_sha256"]

    assert baseline["extensions_sha256"] ==
             :crypto.hash(:sha256, File.read!("priv/openapi-extensions.json"))
             |> Base.encode16(case: :lower)

    assert Enum.map(actual, &Map.take(&1, ["source_file", "source"])) ==
             Enum.map(baseline["issues"], &Map.take(&1, ["source_file", "source"])),
           "Upstream example/schema discrepancies changed; review the source pointers instead of weakening validation"
  end

  for {path, method, op_id} <- @operations do
    test "#{op_id} matches official method, route, query, body and response schema", %{
      client: client
    } do
      id = unquote(op_id)
      fixture = OpenAPIMock.request_example(id, examples: false)
      spec = Operations.get(id)
      assert Atom.to_string(spec.id) == Macro.underscore(id)
      assert Atom.to_string(fixture.method) == unquote(method)

      path_names =
        Regex.scan(~r/\{([^}]+)\}/, unquote(path), capture: :all_but_first) |> List.flatten()

      args = [client | Enum.map(path_names, &Map.fetch!(fixture.path_params, &1))]
      args = if fixture.content_type, do: args ++ [fixture.body], else: args
      requests = if map_size(fixture.query) == 0, do: 2, else: 1
      module = Module.concat(ExFattureincloud, spec.module)
      expected = expected_response_body(id)

      OpenAPIMock.expect(__MODULE__, id,
        count: requests,
        examples: false,
        on_request: fn conn ->
          assert conn.request_path == fixture.path

          assert fetch_query_params(conn).query_params ==
                   Map.new(fixture.query, fn {key, value} -> {key, to_string(value)} end)

          assert_serialized_body(conn, fixture)
        end
      )

      assert {:ok, response} = apply(module, spec.id, args ++ [fixture.query])
      assert response.body === expected
      assert response.data === response_data(expected)

      if map_size(fixture.query) == 0 do
        assert {:ok, response} = apply(module, spec.id, args)
        assert response.body === expected
      else
        assert {:error, %Error{kind: :validation}} = apply(module, spec.id, args)
      end

      Req.Test.verify!(__MODULE__)
    end
  end

  test "required query, enums, bounds and typos are checked before HTTP", %{client: client} do
    for {operation, options} <- [
          {:list_clients, [path: [company_id: nil]]},
          {:list_clients, [path: [company_id: 0]]},
          {:list_clients, [path: [company_id: 1, typo: 2]]},
          {:list_issued_documents, [path: [company_id: 1]]},
          {:list_issued_documents, [path: [company_id: 1], query: [type: "nonexistent"]]},
          {:list_clients, [path: [company_id: 1], query: [per_page: 101]]},
          {:list_clients, [path: [company_id: 1], query: [page: 0]]},
          {:list_clients, [path: [company_id: 1], query: [page: "2"]]},
          {:list_clients, [path: [company_id: 1], query: [perpage: 10]]},
          {:get_e_invoice_xml,
           [path: [company_id: 1, document_id: 2], query: [include_attachment: "false"]]},
          {:list_clients, [path: [company_id: 1], body: %{}]},
          {:create_client, [path: [company_id: 1], multipart: []]},
          {:list_clients, [path: [company_id: 1], unexpected: true]}
        ] do
      assert {:error, %Error{kind: :validation}} =
               ExFattureincloud.call(client, operation, options)
    end
  end

  test "path segments encode slashes, percent and Unicode", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/c/1/subscriptions/SUB%2Fa%20%25%20%C3%A8"
      Req.Test.json(conn, %{})
    end)

    assert {:ok, _} = ExFattureincloud.Webhooks.get_webhooks_subscription(client, 1, "SUB/a % è")
  end

  defp expected_response_body(id) do
    responses = OpenAPIMock.operation(id).raw["responses"]
    status = responses |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "2")) |> Enum.min()
    response = responses |> Map.fetch!(status) |> resolve_response()

    case response["content"] do
      content when content in [nil, %{}] -> ""
      _content -> OpenAPIMock.response_example(id, String.to_integer(status), examples: false)
    end
  end

  defp resolve_response(%{"$ref" => reference}) do
    OpenAPIMock.raw_contract()
    |> get_in(reference |> String.trim_leading("#/") |> String.split("/"))
  end

  defp resolve_response(response), do: response

  defp response_data(%{"data" => data}), do: data
  defp response_data(body), do: body

  defp assert_serialized_body(conn, %{content_type: "application/json", body: body}),
    do: assert(conn.body_params === body)

  defp assert_serialized_body(conn, %{content_type: "multipart/form-data", body: fields}) do
    expected = Map.new(fields, fn {key, value} -> {to_string(key), value} end)
    assert %Plug.Upload{} = conn.body_params["attachment"]
    {bytes, options} = expected["attachment"]
    assert conn.body_params["attachment"].filename == options[:filename]
    assert File.read!(conn.body_params["attachment"].path) == bytes
    assert conn.body_params["filename"] == expected["filename"]
  end

  defp assert_serialized_body(_conn, %{content_type: nil}), do: :ok
end
