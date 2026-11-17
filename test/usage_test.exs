defmodule ExFattureincloud.UsageTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias ExFattureincloud.{Error, Usage}
  alias ExFattureincloud.Usage.Quota

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

  test "reads actual plan counters and annual document capacity", %{client: client} do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/c/123/company/plan_usage"
      assert fetch_query_params(conn).query_params == %{"category" => "documents"}

      conn
      |> put_resp_header("ratelimit-hourlyremaining", "998")
      |> Req.Test.json(%{data: %{limit: 3000, usage: 100}})
    end)

    assert {:ok, %Quota{limit: 3000, used: 100, remaining: 2900, period: :annual} = quota} =
             Usage.documents(client, 123)

    assert quota.api_rate_limit.hourly_remaining == 998
    assert Quota.available?(quota, 2900)
    refute Quota.available?(quota, 2901)
    Req.Test.verify!(__MODULE__)
  end

  for {limit, used, remaining} <- [
        {100, 100, 0},
        {100, 103, 0},
        {0, 0, 0},
        {nil, 1, :unknown},
        {-1, 1, :unknown},
        {100, nil, :unknown},
        {100, "10", :unknown}
      ] do
    expected_available = if remaining == :unknown, do: :unknown, else: remaining > 0

    test "quota limit=#{inspect(limit)}, usage=#{inspect(used)} produces #{inspect(remaining)}",
         %{client: client} do
      Req.Test.stub(
        __MODULE__,
        &Req.Test.json(&1, %{data: %{limit: unquote(limit), usage: unquote(used)}})
      )

      assert {:ok, %{remaining: unquote(remaining)}} = Usage.documents(client, 1)
      assert {:ok, unquote(expected_available)} = Usage.can_create_documents?(client, 1)
    end
  end

  test "other resource limits are global and invalid categories fail locally", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert fetch_query_params(conn).query_params["category"] == "clients"
      Req.Test.json(conn, %{data: %{limit: 5000, usage: 20}})
    end)

    assert {:ok, %{period: :global, remaining: 4980}} = Usage.plan(client, 1, :clients)
    assert {:error, %Error{kind: :validation}} = Usage.plan(client, 1, :invalid)
  end

  test "invoice check combines license, features and detailed permissions", %{client: client} do
    expect_company(%{
      fic_plan_name: "premium_plus",
      fic_license_expire: "2099-12-31",
      plan_info: %{functions: %{e_invoice: true}},
      access_info: %{
        permissions: %{
          fic_issued_documents: "detailed",
          fic_issued_documents_detailed: %{invoices: "write"}
        }
      }
    })

    expect_quota(100, 98)

    assert {:ok,
            %{
              can_create: true,
              quota_available: true,
              e_invoice_enabled: true,
              license_status: :active,
              plan: "premium_plus"
            }} = Usage.invoice_capacity(client, 1, 2)

    Req.Test.verify!(__MODULE__)
  end

  test "quota alone does not imply invoice authorization", %{client: client} do
    expect_company(%{
      fic_license_expire: "2099-12-31",
      plan_info: %{functions: %{e_invoice: false}},
      access_info: %{permissions: %{fic_issued_documents: "read"}}
    })

    expect_quota(100, 1)

    assert {:ok, %{can_create: false, quota_available: true, e_invoice_enabled: false}} =
             Usage.invoice_capacity(client, 1)
  end

  test "expired license blocks creating while missing counters remain unknown", %{client: client} do
    expect_company(%{
      fic_license_expire: "2020-01-01",
      access_info: %{permissions: %{fic_issued_documents: "write"}}
    })

    expect_quota(nil, nil)

    assert {:ok, %{can_create: false, license_status: :expired, quota_available: :unknown}} =
             Usage.invoice_capacity(client, 1)
  end

  test "missing license and permissions produce unknown, never optimistic permission", %{
    client: client
  } do
    expect_company(%{})
    expect_quota(100, 1)

    assert {:ok, %{can_create: :unknown, e_invoice_enabled: :unknown, license_status: :unknown}} =
             Usage.invoice_capacity(client, 1)
  end

  test "errors propagate without reporting quota zero", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> put_status(403) |> Req.Test.json(%{error: %{message: "No permission"}})
    end)

    assert {:error, %Error{status: 403}} = Usage.documents(client, 1)
  end

  test "API usage preserves provider custom limits and shared app_id null", %{client: client} do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/c/1/info/api_usage"

      Req.Test.json(conn, %{
        data: %{
          app_id: nil,
          hourly: %{limit: 2000, usage: 160, remaining: 1840},
          monthly: %{limit: 40_000, usage: 12_570, remaining: 27_430}
        }
      })
    end)

    assert {:ok, %{data: %{"app_id" => nil, "hourly" => %{"limit" => 2000, "remaining" => 1840}}}} =
             Usage.api(client, 1)

    Req.Test.verify!(__MODULE__)
  end

  defp expect_company(info), do: Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: info}))

  defp expect_quota(limit, used),
    do: Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{data: %{limit: limit, usage: used}}))
end
