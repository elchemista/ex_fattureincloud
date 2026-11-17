defmodule ExFattureincloud.OpenAPIMockTest do
  use ExUnit.Case, async: true

  @moduletag :contract

  alias ExFattureincloud.{Clients, Companies, IssuedDocuments, IssuedEInvoices}
  alias ExFattureincloud.TestSupport.OpenAPIMock, as: Mock

  setup do
    client =
      ExFattureincloud.new(
        token: "mock-token",
        max_retries: 0,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    %{client: client}
  end

  test "official examples are validated and returned without normalization", %{client: client} do
    expected = %{"data" => %{"limit" => 3000, "usage" => 100}}
    assert Mock.response_example("getCompanyPlanUsage") == expected
    Mock.expect(__MODULE__, "getCompanyPlanUsage")

    assert {:ok, %{body: ^expected}} =
             Companies.get_company_plan_usage(client, 12_345, category: "documents")

    Req.Test.verify!(__MODULE__)
  end

  test "schema mode generates valid nested payloads independently of inconsistent examples" do
    fixture = Mock.request_example("createIssuedDocument", examples: false)
    assert fixture.source == :schema
    assert fixture.body["data"]["ei_data"]["vat_kind"] in ["I", "D", "S"]
    assert is_binary(fixture.body["data"]["entity"]["name"])
    assert fixture.path_params["company_id"] == 12_345
    assert fixture.content_type == "application/json"
  end

  test "invalid official examples fail explicitly instead of being silently repaired" do
    assert_raise ExUnit.AssertionError,
                 ~r/createCashbookEntry request example.*Missing field: id/s,
                 fn ->
                   Mock.request_example("createCashbookEntry")
                 end

    assert_raise ExUnit.AssertionError, ~r/ListClientsResponsePage/, fn ->
      Mock.response_example("listClients")
    end
  end

  test "the example audit deduplicates shared references using canonical source pointers" do
    issues = Mock.example_issues()
    sources = Enum.map(issues, &{&1.source_file, &1.source})
    assert sources == Enum.uniq(sources)

    assert Enum.any?(issues, fn issue ->
             issue.source ==
               "#/components/responses/CreateCashbookEntryResponse/content/application~1json/examples/example-1" and
               issue.error =~ "#/data/id"
           end)

    assert Enum.any?(issues, &(&1.error =~ "JSON wire types"))
  end

  test "nested numeric strings are rejected as JSON types, rather than cast into numbers", %{
    client: client
  } do
    Mock.expect(__MODULE__, "createClient", response: %{"data" => %{"id" => 1}})

    assert_raise ExUnit.AssertionError, ~r/JSON wire types/, fn ->
      Clients.create_client(client, 1, %{
        data: %{name: "Rossi", default_vat: %{value: "22"}}
      })
    end
  end

  for {label, body, message} <- [
        {"required nested field", %{data: %{}}, "Missing field: name"},
        {"nested enum", %{data: %{name: "Rossi", type: "alien"}}, "Invalid value for enum"},
        {"nonnullable field", %{data: %{name: nil}}, "null value where string expected"}
      ] do
    test "the HTTP mock rejects an invalid #{label}", %{client: client} do
      Mock.expect(__MODULE__, "createClient", response: %{"data" => %{"id" => 1}})

      assert_raise ExUnit.AssertionError, Regex.compile!(Regex.escape(unquote(message))), fn ->
        Clients.create_client(client, 1, unquote(Macro.escape(body)))
      end
    end
  end

  test "required query parameters are checked on actual HTTP requests", %{client: client} do
    Mock.expect(__MODULE__, "listIssuedDocuments", response: %{"data" => []})

    assert_raise ExUnit.AssertionError, ~r/Missing field: type/, fn ->
      ExFattureincloud.request(client, :get, "/c/1/issued_documents")
    end
  end

  test "query enum and bounds validation do not depend on SDK prevalidation", %{client: client} do
    Mock.expect(__MODULE__, "listClients", response: %{"data" => []})

    assert_raise ExUnit.AssertionError, ~r/maximum/, fn ->
      ExFattureincloud.request(client, :get, "/c/1/entities/clients", query: [per_page: 101])
    end
  end

  test "invalid path values and missing path segments fail", %{client: client} do
    Mock.expect(__MODULE__, "getCompanyInfo", response: %{"data" => %{}})

    assert_raise ExUnit.AssertionError, ~r/company_id/, fn ->
      ExFattureincloud.request(client, :get, "/c/not-an-integer/company/info")
    end

    Mock.expect(__MODULE__, "getCompanyInfo", response: %{"data" => %{}})

    assert_raise ExUnit.AssertionError, ~r/unexpected request path/, fn ->
      ExFattureincloud.request(client, :get, "/c//company/info")
    end
  end

  test "static routes cannot be mistaken for dynamic resource IDs", %{client: client} do
    Mock.expect(__MODULE__, "getClient", response: %{"data" => %{"id" => 1}})

    assert_raise ExUnit.AssertionError, ~r/client_id/, fn ->
      ExFattureincloud.request(client, :get, "/c/1/entities/clients/info")
    end

    Mock.expect(__MODULE__, "getClientInfo", response: %{"data" => %{}})
    assert {:ok, _} = Clients.get_client_info(client, 1)
    Req.Test.verify!(__MODULE__)
  end

  test "HTTP method and authorization are checked before sending a mock response", %{
    client: client
  } do
    Mock.expect(__MODULE__, "getCompanyInfo", response: %{"data" => %{}})

    assert_raise ExUnit.AssertionError, ~r/unexpected HTTP method/, fn ->
      ExFattureincloud.request(client, :post, "/c/1/company/info")
    end

    Mock.expect(__MODULE__, "getCompanyInfo", response: %{"data" => %{}})

    assert_raise ExUnit.AssertionError, ~r/Bearer authorization/, fn ->
      ExFattureincloud.request(client, :get, "/c/1/company/info", authenticated: false)
    end
  end

  test "invalid response enums, nulls and wire types are rejected before registration" do
    for response <- [
          %{"data" => %{"id" => "123"}},
          %{"data" => %{"type" => "alien"}},
          %{"data" => %{"default_vat" => %{"value" => "22"}}}
        ] do
      assert_raise ExUnit.AssertionError, fn ->
        Mock.expect(__MODULE__, "getClient", response: response)
      end
    end

    assert_raise ExUnit.AssertionError, ~r/null value where object expected/, fn ->
      Mock.expect(__MODULE__, "listClients",
        response: %{"data" => [%{"default_payment_method" => nil}]}
      )
    end
  end

  test "validation preserves unknown string keys and exact original JSON values", %{
    client: client
  } do
    future_key = "future-key-#{System.unique_integer([:positive])}"
    expected = %{"data" => %{"id" => 1, future_key => %{"amount" => "1.00000"}}}
    Mock.expect(__MODULE__, "getClient", response: expected)

    assert {:ok, %{body: ^expected}} = Clients.get_client(client, 1, 1)
    assert_raise ArgumentError, fn -> String.to_existing_atom(future_key) end
    Req.Test.verify!(__MODULE__)
  end

  test "on_request observes original parsed JSON before casting", %{client: client} do
    payload = %{"data" => %{"name" => "Caffè", "notes" => "", "e_invoice" => false}}

    Mock.expect(__MODULE__, "createClient",
      response: %{"data" => %{"id" => 1}},
      on_request: fn conn -> assert conn.body_params == payload end
    )

    assert {:ok, _} = Clients.create_client(client, 1, payload)
    Req.Test.verify!(__MODULE__)
  end

  test "multipart is parsed as a real upload and schema validated", %{client: client} do
    Mock.expect(__MODULE__, "uploadIssuedDocumentAttachment",
      response: %{"data" => %{"attachment_token" => "uploaded"}},
      on_request: fn conn ->
        assert conn.body_params["filename"] == "attachment.bin"

        assert %Plug.Upload{filename: "attachment.bin", path: path} =
                 conn.body_params["attachment"]

        assert File.read!(path) == <<0, 255, 42>>
      end
    )

    fields = [
      filename: "attachment.bin",
      attachment: {<<0, 255, 42>>, filename: "attachment.bin"}
    ]

    assert {:ok, _} = IssuedDocuments.upload_issued_document_attachment(client, 1, fields)
    Req.Test.verify!(__MODULE__)
  end

  test "XML and empty response bodies follow their declared media contracts", %{client: client} do
    xml = "<?xml version=\"1.0\"?><FatturaElettronica/>"
    Mock.expect(__MODULE__, "getEInvoiceXml", response: xml)
    assert {:ok, %{body: ^xml}} = IssuedEInvoices.get_e_invoice_xml(client, 1, 2)

    assert Mock.response_example("deleteClient", nil, examples: false) == nil
    Mock.expect(__MODULE__, "deleteClient")
    assert {:ok, %{body: ""}} = Clients.delete_client(client, 1, 2)
    Req.Test.verify!(__MODULE__)
  end

  test "an optional request body can be omitted without changing the official contract", %{
    client: client
  } do
    Mock.expect(__MODULE__, "sendEInvoice", response: %{"data" => %{}})
    assert {:ok, _} = IssuedEInvoices.send_e_invoice(client, 1, 2, nil)
    Req.Test.verify!(__MODULE__)
  end

  test "the documented extension is identified and its response is independently validated", %{
    client: client
  } do
    assert Mock.operation("getApiUsage").extension?
    refute Mock.operation("getCompanyInfo").extension?
    Mock.expect(__MODULE__, "getApiUsage")

    assert {:ok, %{data: %{"hourly" => %{"remaining" => 840}}}} =
             Companies.get_api_usage(client, 1)

    Req.Test.verify!(__MODULE__)
  end
end
