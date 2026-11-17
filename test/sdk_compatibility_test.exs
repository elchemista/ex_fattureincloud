defmodule ExFattureincloud.SDKCompatibilityTest do
  @moduledoc """
  Transport compatibility regressions for every audited upstream example which
  contradicts its schema. Direct Req.Test responses intentionally bypass the
  strict contract mock here: these tests prove wire-value preservation, not that
  the provider will accept inconsistent requests or return these responses.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  alias ExFattureincloud.Client
  alias ExFattureincloud.TestSupport.OpenAPIMock, as: Mock

  @moduletag :sdk_compatibility
  @fixture "test/fixtures/sdk_compatibility_cases.json" |> File.read!() |> Jason.decode!()
  @cases @fixture["cases"]

  setup do
    client =
      ExFattureincloud.new(
        token: "compatibility-token",
        max_retries: 0,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    %{client: client}
  end

  test "compatibility cases bind all 26 audited examples to the pinned official contract" do
    metadata = "priv/openapi-source.json" |> File.read!() |> Jason.decode!()

    actual_hash =
      :crypto.hash(:sha256, File.read!(@fixture["source_file"]))
      |> Base.encode16(case: :lower)

    assert actual_hash == @fixture["contract_sha256"]
    assert metadata["commit"] == @fixture["source_commit"]
    assert length(@cases) == 26
    assert Enum.map(@cases, & &1["id"]) == Enum.to_list(1..26)

    audited_sources =
      Mock.example_issues()
      |> Enum.filter(&(&1.source_file == @fixture["source_file"]))
      |> MapSet.new(& &1.source)

    assert MapSet.new(@cases, & &1["source"]) == audited_sources
  end

  for example <- @cases, example["phase"] == "response" do
    @tag source: example["source"], model: example["model"]
    test "case #{example["id"]}: preserves the complete #{example["model"]} response",
         %{client: client} do
      example = unquote(Macro.escape(example))
      operation_id = hd(example["operations"])
      request = Mock.request_example(operation_id, examples: false)
      original = official_value(example["source"])

      Req.Test.expect(__MODULE__, fn conn ->
        conn = assert_request(conn, request, request.body)
        Req.Test.json(conn, original)
      end)

      assert {:ok, response} = invoke(client, operation_id, request, request.body)
      assert response.body === original
      assert response.data === original["data"]
      Req.Test.verify!(__MODULE__)
    end
  end

  for example <- @cases, example["phase"] == "request" do
    @tag source: example["source"], model: example["model"]
    test "case #{example["id"]}: transmits the original #{example["model"]} request unchanged",
         %{client: client} do
      example = unquote(Macro.escape(example))
      operation_id = hd(example["operations"])
      request = Mock.request_example(operation_id, examples: false)
      original = official_value(example["source"])
      generated_response = Mock.response_example(operation_id, nil, examples: false)

      Req.Test.expect(__MODULE__, fn conn ->
        conn = assert_request(conn, request, original)
        Req.Test.json(conn, generated_response)
      end)

      assert {:ok, response} = invoke(client, operation_id, request, original)
      assert response.body === generated_response
      Req.Test.verify!(__MODULE__)
    end
  end

  @spec official_value(String.t()) :: map()
  defp official_value(source) do
    path =
      source
      |> String.trim_leading("#/")
      |> String.split("/")
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))

    value = get_in(Mock.raw_contract(), path ++ ["value"])
    assert is_map(value), "upstream example not found at #{source}"
    value
  end

  @spec invoke(Client.t(), String.t(), map(), map() | nil) :: ExFattureincloud.Response.result()
  defp invoke(client, operation_id, request, body) do
    options = [path: request.path_params, query: request.query]
    options = if is_nil(body), do: options, else: Keyword.put(options, :body, body)
    ExFattureincloud.call(client, operation_id, options)
  end

  @spec assert_request(Plug.Conn.t(), map(), map() | nil) :: Plug.Conn.t()
  defp assert_request(conn, request, expected_body) do
    assert conn.method == String.upcase(to_string(request.method))
    assert conn.request_path == request.path
    assert get_req_header(conn, "authorization") == ["Bearer compatibility-token"]

    expected_query = Map.new(request.query, fn {key, value} -> {key, to_string(value)} end)
    assert fetch_query_params(conn).query_params === expected_query
    assert_json_body(conn, expected_body)
  end

  @spec assert_json_body(Plug.Conn.t(), map() | nil) :: Plug.Conn.t()
  defp assert_json_body(conn, nil), do: conn

  defp assert_json_body(conn, expected) do
    assert get_req_header(conn, "content-type") == ["application/json"]
    {:ok, bytes, conn} = read_body(conn)
    assert Jason.decode!(bytes) === expected
    conn
  end
end
