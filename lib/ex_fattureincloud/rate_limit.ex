defmodule ExFattureincloud.RateLimit do
  @moduledoc "Parses hourly/monthly quotas and Retry-After (seconds or HTTP date)."
  defstruct [:hourly_remaining, :hourly_limit, :monthly_remaining, :monthly_limit, :retry_after]

  @type t :: %__MODULE__{
          hourly_remaining: integer() | nil,
          hourly_limit: integer() | nil,
          monthly_remaining: integer() | nil,
          monthly_limit: integer() | nil,
          retry_after: non_neg_integer() | nil
        }

  @spec from_headers(map() | list()) :: t()
  def from_headers(headers) do
    headers =
      Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), List.wrap(value)} end)

    %__MODULE__{
      hourly_remaining: integer(headers, "ratelimit-hourlyremaining"),
      hourly_limit: integer(headers, "ratelimit-hourlylimit"),
      monthly_remaining: integer(headers, "ratelimit-monthlyremaining"),
      monthly_limit: integer(headers, "ratelimit-monthlylimit"),
      retry_after: retry_after(headers)
    }
  end

  defp integer(headers, key) do
    case headers |> Map.get(key, []) |> List.first() do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int >= 0 -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp retry_after(headers) do
    case integer(headers, "retry-after") do
      nil -> date_delay(headers |> Map.get("retry-after", []) |> List.first())
      seconds -> seconds
    end
  end

  defp date_delay(value) when is_binary(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{_, _, _}, {_, _, _}} = date ->
        max(
          0,
          :calendar.datetime_to_gregorian_seconds(date) -
            :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
        )

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp date_delay(_), do: nil
end
