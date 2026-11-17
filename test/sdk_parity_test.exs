defmodule ExFattureincloud.SDKParityTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias ExFattureincloud.{Clients, Error, IssuedDocuments, IssuedEInvoices, OAuth}
  @fixtures "test/fixtures/official_sdk.json" |> File.read!() |> Jason.decode!()

  setup do
    %{
      client:
        ExFattureincloud.new(
          token: "token",
          max_retries: 0,
          req_options: [plug: {Req.Test, __MODULE__}]
        )
    }
  end

  test "official TS issued-document fixture survives without dropping nulls, precision or dates",
       %{client: client} do
    expected = @fixtures["issued_document"]["value"]
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, expected))
    assert {:ok, response} = IssuedDocuments.get_issued_document(client, 1, 12345)
    assert response.body == expected
    assert response.data["items_list"] |> hd() |> Map.fetch!("net_price") == 68.18182
    assert response.data["currency"]["exchange_rate"] == "1.00000"
    assert response.data["payments_list"] |> hd() |> Map.fetch!("paid_date") == nil
    assert response.data["e_invoice"] == false
    assert response.data["stamp_duty"] == 0
    assert response.data["date"] == "2021-08-20"
  end

  test "official TS client pagination envelope is preserved in full", %{client: client} do
    expected = @fixtures["clients_page"]["value"]
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, expected))
    assert {:ok, response} = Clients.list_clients(client, 1)
    assert response.body == expected
    assert response.pagination["last_page"] == 2
    assert response.pagination["next_page_url"] == "page=2"
    assert response.pagination["total"] == 8
  end

  test "official TS XML invoice is returned byte for byte", %{client: client} do
    xml = @fixtures["e_invoice_xml"]["value"]

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> put_resp_content_type("text/xml") |> resp(200, xml)
    end)

    assert {:ok, %{body: ^xml, data: ^xml}} = IssuedEInvoices.get_e_invoice_xml(client, 1, 2)
  end

  test "official validation errors keep totals and validation_result", %{client: client} do
    expected = @fixtures["ApiErrorResponse_validation_error"]["value"]
    Req.Test.stub(__MODULE__, fn conn -> conn |> put_status(422) |> Req.Test.json(expected) end)

    assert {:error, %Error{body: ^expected}} =
             IssuedDocuments.create_issued_document(client, 1, %{data: %{}})
  end

  test "official OAuth error fixture has string error and error_description", %{client: client} do
    expected = @fixtures["ApiErrorResponse_oauth_error"]["value"]
    Req.Test.stub(__MODULE__, fn conn -> conn |> put_status(400) |> Req.Test.json(expected) end)

    assert {:error, %Error{code: "invalid_request", body: ^expected}} =
             OAuth.device_token(client, client_id: "app", device_code: "code")
  end

  test "e-invoice XML validation errors preserve the specific OpenAPI schema", %{client: client} do
    expected = %{
      "error" => %{
        "message" => "XML non valido",
        "validation_result" => %{"xml_errors" => ["Missing required element"]}
      },
      "extra" => %{"errors" => ["Invalid recipient"]}
    }

    Req.Test.stub(__MODULE__, fn conn -> conn |> put_status(422) |> Req.Test.json(expected) end)

    assert {:error, %Error{status: 422, body: ^expected}} =
             IssuedEInvoices.verify_e_invoice_xml(client, 1, 2)
  end

  test "a real file stream sends bytes and filename, not its path", %{client: client} do
    path = Path.join(System.tmp_dir!(), "fic-upload-#{System.unique_integer([:positive])}.bin")
    bytes = <<0, 255, 10, 13, 42, 128>>
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert body =~ bytes
      assert body =~ "filename=\"attachment.bin\""
      refute body =~ path
      Req.Test.json(conn, %{data: %{attachment_token: "token"}})
    end)

    fields = [
      filename: "attachment.bin",
      attachment:
        {File.stream!(path), filename: "attachment.bin", content_type: "application/octet-stream"}
    ]

    assert {:ok, %{data: %{"attachment_token" => "token"}}} =
             IssuedDocuments.upload_issued_document_attachment(client, 1, fields)

    Req.Test.verify!(__MODULE__)
  end

  test "unreadable file streams return a local structured error", %{client: client} do
    path = Path.join(System.tmp_dir!(), "missing-fic-#{System.unique_integer([:positive])}")

    fields = [
      filename: "attachment.bin",
      attachment: {File.stream!(path), filename: "attachment.bin"}
    ]

    assert {:error, %Error{kind: :validation, cause: %File.Error{}}} =
             IssuedDocuments.upload_issued_document_attachment(client, 1, fields)
  end
end
