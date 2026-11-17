defmodule ExFattureincloud.Usage.Quota do
  @moduledoc "A plan quota reported by the provider. Unknown/null values stay unknown."
  defstruct [:category, :period, :limit, :used, :remaining, :checked_at, :api_rate_limit]

  @type t :: %__MODULE__{
          category: String.t(),
          period: :annual | :global,
          limit: number() | nil,
          used: number() | nil,
          remaining: number() | :unknown,
          checked_at: DateTime.t(),
          api_rate_limit: ExFattureincloud.RateLimit.t()
        }

  @doc "Whether the quota has room for count new resources. Does not reserve capacity."
  @spec available?(t(), pos_integer()) :: boolean() | :unknown
  def available?(quota, count \\ 1)

  def available?(%__MODULE__{remaining: :unknown}, count) when is_integer(count) and count > 0,
    do: :unknown

  def available?(%__MODULE__{remaining: remaining}, count) when is_integer(count) and count > 0,
    do: remaining >= count
end

defmodule ExFattureincloud.Usage do
  @moduledoc """
  Reads actual company plan limits instead of hardcoding commercial plans.

  `documents/2` returns the annual document quota, consumption and remaining
  capacity. This is the plan's document counter, not a dedicated SDI sending
  counter. `plan/3` also supports clients, suppliers and products (global quotas).
  `invoice_capacity/3` combines the document counter with company plan features,
  license date and invoice permissions. It performs two GETs and never creates
  or sends an invoice. `api/2` retrieves detailed API counters (one additional
  request); ordinary responses already expose counters in `rate_limit` for free.

  These are point-in-time checks: another user or app can consume the same quota
  after a check. An unknown/null limit does not mean unlimited. Availability for
  creating a document does not guarantee SDI acceptance or permission to send an
  existing document. The provider remains authoritative for every write.
  """
  alias ExFattureincloud.{Client, Companies, Error, Response}
  alias ExFattureincloud.Usage.Quota
  @categories ~w(documents clients suppliers products)

  @doc "Reads the annual document quota and computes remaining capacity."
  @spec documents(Client.t(), integer() | String.t()) :: {:ok, Quota.t()} | {:error, Error.t()}
  def documents(client, company_id), do: plan(client, company_id, :documents)

  @doc "Reads a plan quota for :documents, :clients, :suppliers or :products."
  @spec plan(Client.t(), integer() | String.t(), atom() | String.t()) ::
          {:ok, Quota.t()} | {:error, Error.t()}
  def plan(client, company_id, category) when is_atom(category),
    do: plan(client, company_id, Atom.to_string(category))

  def plan(client, company_id, category) when category in @categories do
    client
    |> Companies.get_company_plan_usage(company_id, category: category)
    |> quota_result(category)
  end

  def plan(_client, _company_id, _category),
    do: {:error, Error.validation("unsupported quota category")}

  @doc "Checks document quota for count new documents; returns :unknown when the counter is unavailable."
  @spec can_create_documents?(Client.t(), integer() | String.t(), pos_integer()) ::
          {:ok, boolean() | :unknown} | {:error, Error.t()}
  def can_create_documents?(client, company_id, count \\ 1)
      when is_integer(count) and count > 0 do
    with {:ok, quota} <- documents(client, company_id), do: {:ok, Quota.available?(quota, count)}
  end

  @doc "Returns document quota, plan, license and invoice feature/permission checks (two API requests)."
  @spec invoice_capacity(Client.t(), integer() | String.t(), pos_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def invoice_capacity(client, company_id, count \\ 1) when is_integer(count) and count > 0 do
    with {:ok, %Response{data: %{} = info}} <- Companies.get_company_info(client, company_id),
         {:ok, quota} <- documents(client, company_id) do
      {:ok, capacity(info, quota, count)}
    else
      {:error, _} = error -> error
      _ -> {:error, %Error{kind: :protocol, message: "invalid company info response"}}
    end
  end

  @doc "Retrieves hourly/monthly API usage, including custom limits and remaining counts. Consumes one request."
  @spec api(Client.t(), integer() | String.t()) :: Response.result()
  defdelegate api(client, company_id), to: Companies, as: :get_api_usage

  @spec quota_result(Response.result(), String.t()) :: {:ok, Quota.t()} | {:error, Error.t()}
  defp quota_result({:ok, %Response{data: %{} = data, rate_limit: rate_limit}}, category) do
    limit = nonnegative(data["limit"])
    used = nonnegative(data["usage"])

    {:ok,
     %Quota{
       category: category,
       period: quota_period(category),
       limit: limit,
       used: used,
       remaining: remaining(limit, used),
       checked_at: DateTime.utc_now(),
       api_rate_limit: rate_limit
     }}
  end

  defp quota_result({:error, _error} = result, _category), do: result

  defp quota_result(_response, _category),
    do: {:error, %Error{kind: :protocol, message: "invalid company plan usage response"}}

  @spec capacity(map(), Quota.t(), pos_integer()) :: map()
  defp capacity(info, quota, count) do
    license = license_status(info["fic_license_expire"])
    permission = info |> get_in(["access_info", "permissions"]) |> invoice_permission()
    available = Quota.available?(quota, count)

    %{
      documents: quota,
      requested: count,
      can_create: combine([available, permission, license_active?(license)]),
      quota_available: available,
      e_invoice_enabled:
        info |> get_in(["plan_info", "functions", "e_invoice"]) |> feature_enabled(),
      invoice_write_permission: permission,
      plan: info["fic_plan_name"],
      license_expire: info["fic_license_expire"],
      license_status: license
    }
  end

  @spec remaining(number() | nil, number() | nil) :: number() | :unknown
  defp remaining(limit, used) when is_number(limit) and is_number(used), do: max(0, limit - used)
  defp remaining(_limit, _used), do: :unknown
  @spec quota_period(String.t()) :: :annual | :global
  defp quota_period("documents"), do: :annual
  defp quota_period(_category), do: :global
  @spec feature_enabled(term()) :: boolean() | :unknown
  defp feature_enabled(value) when is_boolean(value), do: value
  defp feature_enabled(_value), do: :unknown
  @spec nonnegative(term()) :: number() | nil
  defp nonnegative(value) when is_number(value) and value >= 0, do: value
  defp nonnegative(_), do: nil

  @spec license_status(term()) :: :active | :expired | :unknown
  defp license_status(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> if Date.compare(date, Date.utc_today()) == :lt, do: :expired, else: :active
      _ -> :unknown
    end
  end

  defp license_status(_), do: :unknown

  @spec license_active?(:active | :expired | :unknown) :: boolean() | :unknown
  defp license_active?(:active), do: true
  defp license_active?(:expired), do: false
  defp license_active?(:unknown), do: :unknown

  @spec invoice_permission(term()) :: boolean() | :unknown
  defp invoice_permission(%{"fic_issued_documents" => "detailed"} = permissions),
    do: permissions |> get_in(["fic_issued_documents_detailed", "invoices"]) |> permission_level()

  defp invoice_permission(%{"fic_issued_documents" => level}), do: permission_level(level)
  defp invoice_permission(_permissions), do: :unknown

  @spec permission_level(term()) :: boolean() | :unknown
  defp permission_level("write"), do: true
  defp permission_level(level) when level in ["none", "read"], do: false
  defp permission_level(_level), do: :unknown

  @spec combine([boolean() | :unknown]) :: boolean() | :unknown
  defp combine(values) do
    cond do
      false in values -> false
      :unknown in values -> :unknown
      true -> true
    end
  end
end
