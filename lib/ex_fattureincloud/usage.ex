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
  def plan(client, company_id, category) when is_atom(category) or is_binary(category) do
    category = to_string(category)

    if category in @categories do
      with {:ok, %Response{data: %{} = data} = response} <-
             Companies.get_company_plan_usage(client, company_id, category: category) do
        limit = nonnegative(data["limit"])
        used = nonnegative(data["usage"])

        remaining =
          if is_number(limit) and is_number(used), do: max(0, limit - used), else: :unknown

        {:ok,
         %Quota{
           category: category,
           period: if(category == "documents", do: :annual, else: :global),
           limit: limit,
           used: used,
           remaining: remaining,
           checked_at: DateTime.utc_now(),
           api_rate_limit: response.rate_limit
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, %Error{kind: :protocol, message: "invalid company plan usage response"}}
      end
    else
      {:error, Error.validation("unsupported quota category")}
    end
  end

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
      feature = get_in(info, ["plan_info", "functions", "e_invoice"])
      feature = if is_boolean(feature), do: feature, else: :unknown
      license = license_status(info["fic_license_expire"])
      permission = invoice_permission(info)
      available = Quota.available?(quota, count)

      can_create =
        combine([
          available,
          permission,
          case license do
            :active -> true
            :expired -> false
            :unknown -> :unknown
          end
        ])

      {:ok,
       %{
         documents: quota,
         requested: count,
         can_create: can_create,
         quota_available: available,
         e_invoice_enabled: feature,
         invoice_write_permission: permission,
         plan: info["fic_plan_name"],
         license_expire: info["fic_license_expire"],
         license_status: license
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, %Error{kind: :protocol, message: "invalid company info response"}}
    end
  end

  @doc "Retrieves hourly/monthly API usage, including custom limits and remaining counts. Consumes one request."
  @spec api(Client.t(), integer() | String.t()) :: Response.result()
  defdelegate api(client, company_id), to: Companies, as: :get_api_usage

  defp nonnegative(value) when is_number(value) and value >= 0, do: value
  defp nonnegative(_), do: nil

  defp license_status(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> if Date.compare(date, Date.utc_today()) == :lt, do: :expired, else: :active
      _ -> :unknown
    end
  end

  defp license_status(_), do: :unknown

  defp invoice_permission(info) do
    permissions = get_in(info, ["access_info", "permissions"]) || %{}

    case permissions["fic_issued_documents"] do
      "write" ->
        true

      "none" ->
        false

      "read" ->
        false

      "detailed" ->
        case get_in(permissions, ["fic_issued_documents_detailed", "invoices"]) do
          "write" -> true
          level when level in ["none", "read"] -> false
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  defp combine(values) do
    cond do
      false in values -> false
      :unknown in values -> :unknown
      true -> true
    end
  end
end
