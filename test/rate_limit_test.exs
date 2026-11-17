defmodule ExFattureincloud.RateLimitTest do
  use ExUnit.Case, async: true
  alias ExFattureincloud.RateLimit

  test "case insensitive headers, zero remaining and malformed values" do
    limit =
      RateLimit.from_headers([
        {"RateLimit-HourlyRemaining", "0"},
        {"Retry-After", "15"},
        {"RateLimit-MonthlyLimit", "nope"}
      ])

    assert limit.hourly_remaining == 0
    assert limit.retry_after == 15
    assert limit.monthly_limit == nil
    assert RateLimit.from_headers(%{}).retry_after == nil
    assert RateLimit.from_headers(%{"retry-after" => ["invalid"]}).retry_after == nil
    assert RateLimit.from_headers(%{"retry-after" => ["-1"]}).retry_after == nil
  end

  test "HTTP date Retry-After is converted to a nonnegative wait" do
    header =
      DateTime.utc_now() |> DateTime.add(60) |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    assert RateLimit.from_headers(%{"retry-after" => [header]}).retry_after in 59..60

    assert RateLimit.from_headers(%{"retry-after" => ["Sun, 06 Nov 1994 08:49:37 GMT"]}).retry_after ==
             0
  end
end
