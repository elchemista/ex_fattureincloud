defmodule ExFattureincloud.PaginationTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias ExFattureincloud.{Error, Pagination}

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

  test "lazy stream preserves filters, starts from requested page and fetches through last_page",
       %{client: client} do
    stream =
      Pagination.stream!(client, :list_clients,
        path: [company_id: 1],
        query: [page: 2, q: "name = 'Rossi'", per_page: 1]
      )

    Req.Test.expect(__MODULE__, fn conn ->
      assert fetch_query_params(conn).query_params == %{
               "page" => "2",
               "q" => "name = 'Rossi'",
               "per_page" => "1"
             }

      Req.Test.json(conn, %{data: [%{id: 2}], current_page: 2, last_page: 3})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert fetch_query_params(conn).query_params["page"] == "3"
      Req.Test.json(conn, %{data: [%{id: 3}], current_page: 3, last_page: 3})
    end)

    assert Enum.to_list(stream) == [%{"id" => 2}, %{"id" => 3}]
    Req.Test.verify!(__MODULE__)
  end

  test "take stops before the next request", %{client: client} do
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: [%{id: 1}, %{id: 2}], last_page: 100}))

    assert client |> Pagination.stream!(:list_clients, path: [company_id: 1]) |> Enum.take(1) == [
             %{"id" => 1}
           ]

    Req.Test.verify!(__MODULE__)
  end

  test "an empty page halts even when last_page claims more results", %{client: client} do
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: [], last_page: 100}))
    assert Enum.to_list(Pagination.stream(client, :list_clients, path: [company_id: 1])) == []
    Req.Test.verify!(__MODULE__)
  end

  test "next_page_url is a hint and is never followed to a different host", %{client: client} do
    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{data: [%{id: 1}], next_page_url: "https://evil.example.com"})
    )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "api-v2.fattureincloud.it"
      assert fetch_query_params(conn).query_params["page"] == "2"
      Req.Test.json(conn, %{data: [%{id: 2}], next_page_url: nil})
    end)

    assert length(Enum.to_list(Pagination.stream!(client, :list_clients, path: [company_id: 1]))) ==
             2
  end

  test "failure after a successful page is emitted and halts", %{client: client} do
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: [%{id: 1}], last_page: 2}))

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> put_status(401) |> Req.Test.json(%{error: %{message: "Expired"}})
    end)

    assert [{:ok, %{"id" => 1}}, {:error, %Error{status: 401}}] =
             Enum.to_list(Pagination.stream(client, :list_clients, path: [company_id: 1]))
  end

  test "bang stream raises rather than silently truncating", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn -> conn |> put_status(401) |> Req.Test.json(%{}) end)

    assert_raise Error, fn ->
      Enum.to_list(Pagination.stream!(client, :list_clients, path: [company_id: 1]))
    end
  end

  test "malformed successful data is a protocol error", %{client: client} do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{data: %{unexpected: "map"}}))

    assert [{:error, %Error{kind: :protocol}}] =
             Enum.to_list(Pagination.stream(client, :list_clients, path: [company_id: 1]))
  end

  test "nonpaginated operations are rejected", %{client: client} do
    assert_raise ArgumentError, fn -> Pagination.stream(client, :get_user_info) end
  end

  test "missing pagination metadata cannot silently truncate results", %{client: client} do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{data: [%{id: 1}]}))

    assert [{:error, %Error{kind: :protocol}}] =
             Enum.to_list(Pagination.stream(client, :list_clients, path: [company_id: 1]))
  end

  test "a server repeating the wrong page is detected", %{client: client} do
    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{data: [%{id: 1}], current_page: 1, last_page: 3})
    )

    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{data: [%{id: 1}], current_page: 1, last_page: 3})
    )

    assert [{:ok, %{"id" => 1}}, {:error, %Error{kind: :protocol}}] =
             Enum.to_list(Pagination.stream(client, :list_clients, path: [company_id: 1]))

    Req.Test.verify!(__MODULE__)
  end

  test "per_page can determine completion when last_page is unavailable", %{client: client} do
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: [%{id: 1}], per_page: 1}))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: [], per_page: 1}))

    assert [%{"id" => 1}] =
             Enum.to_list(Pagination.stream!(client, :list_clients, path: [company_id: 1]))

    Req.Test.verify!(__MODULE__)
  end
end
