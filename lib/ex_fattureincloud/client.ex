defmodule ExFattureincloud.Client do
  @moduledoc """
  Immutable configuration for one integration/account.

  Options to `new/1`:

    * `:token` — access token or zero-arity function returning the current token.
      Omit for OAuth calls; authenticated requests then return an error.
    * `:base_url` — defaults to `https://api-v2.fattureincloud.it`.
    * `:user_agent` — defaults to `FattureInCloud/2.1.3/Go-SDK`, matching the
      official Go SDK's compatibility header. Override for your integration.
    * `:receive_timeout` — milliseconds, default 15,000.
    * `:max_retries` — additional attempts for GET/HEAD only, default 2.
    * `:retry_delay` — initial backoff in milliseconds, default 500, with jitter.
    * `:max_retry_delay` — maximum permitted wait, default 30,000 ms. A server
      `Retry-After` above this budget returns the error without retrying early.
    * `:req_options` — Req options, e.g. `connect_options`, `finch`, `plug` or
      a custom `adapter`. Redirects and Req's own retries are always disabled.

  Token providers are evaluated once per outgoing attempt. Refresh and persistence
  belong to the application so concurrent users never share mutable credentials.
  Inspection of the client excludes credentials and Req options.
  """

  @derive {Inspect, only: [:base_url, :max_retries, :receive_timeout]}
  @enforce_keys [:base_url]
  defstruct [
    :base_url,
    :token,
    user_agent: "FattureInCloud/2.1.3/Go-SDK",
    receive_timeout: 15_000,
    max_retries: 2,
    retry_delay: 500,
    max_retry_delay: 30_000,
    req_options: []
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: nil | String.t() | (-> String.t()),
          user_agent: String.t(),
          receive_timeout: pos_integer(),
          max_retries: non_neg_integer(),
          retry_delay: non_neg_integer(),
          max_retry_delay: non_neg_integer(),
          req_options: keyword()
        }

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    allowed = Map.keys(%__MODULE__{base_url: ""}) -- [:__struct__]
    unknown = Keyword.keys(options) -- allowed
    if unknown != [], do: raise(ArgumentError, "unknown client options: #{inspect(unknown)}")

    client =
      struct!(__MODULE__, Keyword.put_new(options, :base_url, "https://api-v2.fattureincloud.it"))

    uri = URI.parse(client.base_url)

    unless uri.scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "" and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      raise ArgumentError,
            "base_url must be an HTTP(S) URL without credentials, query or fragment"
    end

    unless is_nil(client.token) or (is_binary(client.token) and client.token != "") or
             is_function(client.token, 0),
           do: raise(ArgumentError, "token must be a nonempty string or zero-arity function")

    for key <- [:max_retries, :retry_delay, :max_retry_delay] do
      value = Map.fetch!(client, key)

      unless is_integer(value) and value >= 0,
        do: raise(ArgumentError, "#{key} must be a nonnegative integer")
    end

    unless is_integer(client.receive_timeout) and client.receive_timeout > 0,
      do: raise(ArgumentError, "receive_timeout must be a positive integer")

    unless is_binary(client.user_agent) and client.user_agent != "" and
             not String.contains?(client.user_agent, ["\r", "\n"]),
           do: raise(ArgumentError, "user_agent must be a nonempty HTTP header value")

    unless Keyword.keyword?(client.req_options),
      do: raise(ArgumentError, "req_options must be a keyword list")

    %{client | base_url: String.trim_trailing(client.base_url, "/")}
  end
end
