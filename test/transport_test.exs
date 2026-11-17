defmodule ExFattureincloud.TransportTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias ExFattureincloud.{Clients, Error, IssuedEInvoices, Response, User}

  setup do
    client =
      ExFattureincloud.new(
        token: "token",
        retry_delay: 0,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    %{client: client}
  end

  test "SDK Go User-Agent, bearer token and JSON Accept", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer token"]
      assert get_req_header(conn, "user-agent") == ["FattureInCloud/2.1.3/Go-SDK"]
      assert get_req_header(conn, "accept") == ["application/json"]
      Req.Test.json(conn, %{data: %{id: 42}, extra: true})
    end)

    assert {:ok, %Response{status: 200, data: %{"id" => 42}, body: %{"extra" => true}}} =
             User.get_user_info(client)
  end

  test "user-agent and base URL can be overridden", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "fic.example.com"
      assert get_req_header(conn, "user-agent") == ["MyIntegration/1.0"]
      Req.Test.json(conn, %{data: []})
    end)

    assert {:ok, _} =
             User.get_user_info(%{
               client
               | base_url: "https://fic.example.com",
                 user_agent: "MyIntegration/1.0"
             })
  end

  test "query parameters retain false and encode Unicode, spaces and percent once", %{
    client: client
  } do
    query = "name contains 'Caffè & tè 50%'"

    Req.Test.stub(__MODULE__, fn conn ->
      assert fetch_query_params(conn).query_params == %{
               "q" => query,
               "page" => "2",
               "per_page" => "25"
             }

      Req.Test.json(conn, %{data: [], current_page: 2, last_page: 2})
    end)

    assert {:ok, %{pagination: %{"current_page" => 2}}} =
             Clients.list_clients(client, 7, q: query, page: 2, per_page: 25)
  end

  test "nested JSON keeps explicit nulls, false, dates and decimal values", %{client: client} do
    payload = %{
      data: %{name: "Caffè", notes: nil, enabled: false, date: "2026-11-17", amount: 10.12}
    }

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, bytes, conn} = read_body(conn)

      assert Jason.decode!(bytes) == %{
               "data" => %{
                 "name" => "Caffè",
                 "notes" => nil,
                 "enabled" => false,
                 "date" => "2026-11-17",
                 "amount" => 10.12
               }
             }

      assert get_req_header(conn, "content-type") == ["application/json"]
      Req.Test.json(conn, %{data: %{id: 9}})
    end)

    assert {:ok, %{data: %{"id" => 9}}} = Clients.create_client(client, 7, payload)
  end

  test "XML endpoint advertises text/xml and preserves XML and false query", %{client: client} do
    xml = "<?xml version=\"1.0\"?><FatturaElettronica/>"

    Req.Test.stub(__MODULE__, fn conn ->
      assert get_req_header(conn, "accept") == ["text/xml"]
      assert fetch_query_params(conn).query_params == %{"include_attachment" => "false"}
      conn |> put_resp_content_type("text/xml") |> resp(200, xml)
    end)

    assert {:ok, %{data: ^xml, body: ^xml}} =
             IssuedEInvoices.get_e_invoice_xml(client, 7, 8, include_attachment: false)
  end

  test "empty successful responses are valid", %{client: client} do
    Req.Test.stub(__MODULE__, &resp(&1, 204, ""))
    assert {:ok, %{status: 204, body: ""}} = Clients.delete_client(client, 7, 9)
  end

  test "malformed JSON success is a protocol error with original body", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> put_resp_content_type("application/json") |> resp(200, "{broken")
    end)

    assert {:error, %Error{kind: :protocol, status: 200, body: "{broken"}} =
             User.get_user_info(client)
  end

  test "malformed JSON error retains HTTP status and body", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> put_resp_content_type("application/json") |> resp(422, "{broken")
    end)

    assert {:error, %Error{kind: :http, status: 422, body: "{broken"}} =
             User.get_user_info(client)
  end

  test "HTML proxy errors and JSON suffix media types are handled", %{client: client} do
    Req.Test.expect(__MODULE__, fn conn ->
      conn |> put_resp_content_type("text/html") |> resp(502, "<html>gateway</html>")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_content_type("application/vnd.fic+json")
      |> resp(200, ~s({"data":{"id":1}}))
    end)

    assert {:ok, %{data: %{"id" => 1}}} = User.get_user_info(client)
    Req.Test.verify!(__MODULE__)
  end

  test "full API validation payload and quota headers are preserved", %{client: client} do
    body = %{
      error: %{
        message: "Totali non coerenti",
        code: "VALIDATION",
        validation_result: %{payments: "wrong"}
      },
      extra: %{amount_due: 610}
    }

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> put_resp_header("ratelimit-hourlyremaining", "0")
      |> put_resp_header("ratelimit-monthlylimit", "40000")
      |> put_status(422)
      |> Req.Test.json(body)
    end)

    assert {:error,
            %Error{
              status: 422,
              code: "VALIDATION",
              body: %{"extra" => %{"amount_due" => 610}},
              rate_limit: limit
            } = error} = Clients.create_client(client, 7, %{data: %{}})

    assert limit.hourly_remaining == 0
    assert limit.monthly_limit == 40_000
    refute inspect(error) =~ "payments"
  end

  for status <- [400, 401, 403, 404, 405, 409, 422] do
    test "HTTP #{status} is returned without retry", %{client: client} do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> put_status(unquote(status)) |> Req.Test.json(%{error: %{message: "Failure"}})
      end)

      assert {:error, %Error{status: unquote(status)}} = User.get_user_info(client)
      Req.Test.verify!(__MODULE__)
    end
  end

  for status <- [429, 500, 502, 503, 504] do
    test "safe GET retries HTTP #{status}", %{client: client} do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> put_resp_header("retry-after", "0")
        |> put_status(unquote(status))
        |> Req.Test.json(%{error: %{message: "Temporary"}})
      end)

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: %{id: 1}}))
      assert {:ok, %{data: %{"id" => 1}}} = User.get_user_info(client)
      Req.Test.verify!(__MODULE__)
    end
  end

  test "403 with Retry-After is a retryable quota error", %{client: client} do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_header("retry-after", "0")
      |> put_status(403)
      |> Req.Test.json(%{error: %{message: "Hourly quota exceeded"}})
    end)

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: []}))
    assert {:ok, _} = User.get_user_info(client)
    Req.Test.verify!(__MODULE__)
  end

  test "Retry-After above the wait budget returns immediately", %{client: client} do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_header("retry-after", "3600")
      |> put_status(429)
      |> Req.Test.json(%{error: %{message: "Limit"}})
    end)

    assert {:error, %Error{status: 429, retry_after: 3600}} = User.get_user_info(client)
    Req.Test.verify!(__MODULE__)
  end

  test "retry count is bounded", %{client: client} do
    Req.Test.expect(__MODULE__, 3, fn conn -> conn |> put_status(503) |> Req.Test.json(%{}) end)
    assert {:error, %Error{status: 503}} = User.get_user_info(client)
    Req.Test.verify!(__MODULE__)
  end

  for method <- [:post, :put, :patch, :delete] do
    test "#{method} never retries, including 429", %{client: client} do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> put_resp_header("retry-after", "0") |> put_status(429) |> Req.Test.json(%{})
      end)

      assert {:error, %Error{status: 429}} =
               ExFattureincloud.request(client, unquote(method), "/c/7/custom")

      Req.Test.verify!(__MODULE__)
    end
  end

  test "Req retry override cannot replay a POST", %{client: client} do
    client = %{client | req_options: [plug: {Req.Test, __MODULE__}, retry: :transient]}
    Req.Test.expect(__MODULE__, fn conn -> conn |> put_status(503) |> Req.Test.json(%{}) end)
    assert {:error, %Error{status: 503}} = IssuedEInvoices.send_e_invoice(client, 7, 9, nil)
    Req.Test.verify!(__MODULE__)
  end

  test "redirects are returned as errors without forwarding bearer tokens", %{client: client} do
    Req.Test.expect(__MODULE__, fn conn ->
      conn |> put_resp_header("location", "https://third-party.example.com") |> resp(302, "")
    end)

    assert {:error, %Error{status: 302}} = User.get_user_info(client)
    Req.Test.verify!(__MODULE__)
  end

  test "transport failures are structured and safe reads can retry", %{client: client} do
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: []}))
    assert {:ok, _} = User.get_user_info(client)
    Req.Test.verify!(__MODULE__)
  end

  test "transport failures on writes are never retried", %{client: client} do
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    assert {:error, %Error{kind: :transport, cause: %Req.TransportError{reason: :timeout}}} =
             Clients.create_client(client, 7, %{data: %{}})

    Req.Test.verify!(__MODULE__)
  end

  test "token provider is reevaluated for each attempt", %{client: client} do
    client = %{client | token: fn -> "token-#{Process.get(:token_calls, 0)}" end}

    Req.Test.expect(__MODULE__, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer token-0"]
      Process.put(:token_calls, 1)
      conn |> put_status(503) |> Req.Test.json(%{})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer token-1"]
      Req.Test.json(conn, %{})
    end)

    assert {:ok, _} = User.get_user_info(client)
  end

  test "tagged token-provider errors never trigger a GET retry even with HTTP status", %{
    client: client
  } do
    test_process = self()
    error = %Error{kind: :authentication, status: 503, message: "Refresh unavailable"}

    client = %{
      client
      | token: fn ->
          send(test_process, :provider_called)
          {:error, error}
        end
    }

    assert {:error, ^error} = User.get_user_info(client)
    assert_receive :provider_called
    refute_received :provider_called
  end

  test "telemetry excludes request URL, credentials and response bodies", %{client: client} do
    id = {__MODULE__, make_ref()}
    events = for event <- [:start, :stop, :retry], do: [:ex_fattureincloud, :request, event]

    :telemetry.attach_many(
      id,
      events,
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{data: %{secret: "body-secret"}}))
    assert {:ok, _} = User.get_user_info(client)

    assert_receive {[:ex_fattureincloud, :request, :start], _,
                    %{operation: :get_user_info} = metadata}

    assert Map.keys(metadata) |> Enum.sort() == [:attempt, :method, :operation]
    assert_receive {[:ex_fattureincloud, :request, :stop], %{duration: duration}, %{status: 200}}
    assert duration >= 0
  end

  @doc false
  @spec handle_event([atom()], map(), map(), pid()) :: tuple()
  def handle_event(event, measures, metadata, pid), do: send(pid, {event, measures, metadata})
end
