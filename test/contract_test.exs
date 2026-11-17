defmodule ExFattureincloud.ContractTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias ExFattureincloud.{Error, Operations}

  @specification "priv/openapi.json" |> File.read!() |> Jason.decode!()
  @extensions "priv/openapi-extensions.json" |> File.read!() |> Jason.decode!()
  @paths Map.merge(@specification["paths"], @extensions["paths"])
  @operations for {path, item} <- @paths,
                  {method, operation} <- item,
                  method in ~w(get post put patch delete),
                  do: {path, method, operation, item}

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
    expected = MapSet.new(@operations, fn {_, _, op, _} -> op["operationId"] end)
    assert MapSet.new(Operations.all(), & &1.operation_id) == expected
  end

  test "the vendored contract matches its recorded hash" do
    metadata = "priv/openapi-source.json" |> File.read!() |> Jason.decode!()
    actual = :crypto.hash(:sha256, File.read!("priv/openapi.json")) |> Base.encode16(case: :lower)
    assert actual == metadata["json_sha256"]
    assert @specification["info"]["version"] == metadata["version"]
  end

  for {path, method, operation, item} <- @operations do
    op_id = operation["operationId"]

    test "#{op_id} matches official method, route, query and body", %{client: client} do
      path = unquote(path)
      method = unquote(method)
      operation = unquote(Macro.escape(operation))
      item = unquote(Macro.escape(item))
      spec = Operations.get(operation["operationId"])
      assert Atom.to_string(spec.id) == Macro.underscore(operation["operationId"])

      path_names = Regex.scan(~r/\{([^}]+)\}/, path, capture: :all_but_first) |> List.flatten()

      path_values =
        Map.new(path_names, &{&1, if(&1 == "subscription_id", do: "SUB123", else: 123)})

      expected_path =
        Enum.reduce(path_values, path, fn {key, value}, acc ->
          String.replace(acc, "{" <> key <> "}", to_string(value))
        end)

      query = required_query(item, operation)
      payload = %{data: %{name: "contract", notes: nil, enabled: false}}
      content = get_in(operation, ["requestBody", "content"]) || %{}
      multipart? = Map.has_key?(content, "multipart/form-data")

      fields = [
        filename: "attachment.txt",
        attachment: {"file bytes", filename: "attachment.txt", content_type: "text/plain"}
      ]

      requests = if map_size(query) == 0, do: 2, else: 1

      Req.Test.expect(__MODULE__, requests, fn conn ->
        assert conn.method == String.upcase(method)
        assert conn.request_path == expected_path

        assert fetch_query_params(conn).query_params ==
                 Map.new(query, fn {k, v} -> {k, to_string(v)} end)

        if map_size(content) > 0 do
          {:ok, bytes, conn} = read_body(conn)

          if multipart? do
            assert get_req_header(conn, "content-type")
                   |> hd()
                   |> String.starts_with?("multipart/form-data; boundary=")

            assert bytes =~ "name=\"filename\""
            assert bytes =~ "name=\"attachment\"; filename=\"attachment.txt\""
            assert bytes =~ "file bytes"
          else
            assert Jason.decode!(bytes) == %{
                     "data" => %{"name" => "contract", "notes" => nil, "enabled" => false}
                   }
          end
        end

        Req.Test.json(conn, %{data: %{id: 123}})
      end)

      module = Module.concat(ExFattureincloud, spec.module)
      args = [client] ++ Enum.map(path_names, &path_values[&1])

      args =
        if map_size(content) > 0,
          do: args ++ [if(multipart?, do: fields, else: payload)],
          else: args

      assert {:ok, %{data: %{"id" => 123}}} = apply(module, spec.id, args ++ [query])

      if map_size(query) == 0 do
        assert {:ok, %{data: %{"id" => 123}}} = apply(module, spec.id, args)
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

  defp required_query(item, operation) do
    (Map.get(item, "parameters", []) ++ Map.get(operation, "parameters", []))
    |> Enum.map(fn param ->
      if param["$ref"],
        do: get_in(@specification, String.split(String.trim_leading(param["$ref"], "#/"), "/")),
        else: param
    end)
    |> Enum.filter(&(&1["in"] == "query" and &1["required"]))
    |> Map.new(fn param ->
      schema = param["schema"]

      value =
        cond do
          schema["enum"] -> hd(schema["enum"])
          schema["type"] == "integer" -> 2026
          schema["type"] == "boolean" -> false
          true -> "2026-11-17"
        end

      {param["name"], value}
    end)
  end
end
