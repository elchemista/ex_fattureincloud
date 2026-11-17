defmodule ExFattureincloud.Client do
  @moduledoc """
  Immutable configuration for one integration/account.

  Options to `new/1`:

    * `:token` — access token or zero-arity provider returning the current token,
      `{:ok, token}` or `{:error, %ExFattureincloud.Error{}}`. Omit for OAuth
      calls; authenticated requests then return an error.
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

  Token providers are evaluated once per outgoing attempt. Clients keep no global
  credentials. Optional managed renewal is available through
  `ExFattureincloud.OAuth.TokenManager`; applications supply its storage callbacks.
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

  @typedoc "A token provider's result, including structured authorization failures."
  @type token_result :: String.t() | {:ok, String.t()} | {:error, ExFattureincloud.Error.t()}

  @typedoc "A zero-arity provider evaluated before each outgoing HTTP attempt."
  @type token_provider :: (-> token_result())

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: nil | String.t() | token_provider(),
          user_agent: String.t(),
          receive_timeout: pos_integer(),
          max_retries: non_neg_integer(),
          retry_delay: non_neg_integer(),
          max_retry_delay: non_neg_integer(),
          req_options: keyword()
        }

  @doc "Creates and validates an immutable client configuration. Invalid options raise `ArgumentError`."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    validate_option_names!(options)

    client =
      struct!(__MODULE__, Keyword.put_new(options, :base_url, "https://api-v2.fattureincloud.it"))

    client.base_url |> URI.parse() |> validate_base_url!()
    validate_token!(client.token)

    Enum.each([:max_retries, :retry_delay, :max_retry_delay], fn key ->
      client |> Map.fetch!(key) |> validate_nonnegative!(key)
    end)

    validate_receive_timeout!(client.receive_timeout)
    validate_user_agent!(client.user_agent)
    validate_req_options!(client.req_options)

    %{client | base_url: String.trim_trailing(client.base_url, "/")}
  end

  defp validate_option_names!(options) do
    allowed = Map.keys(%__MODULE__{base_url: ""}) -- [:__struct__]

    case Keyword.keys(options) -- allowed do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown client options: #{inspect(unknown)}"
    end
  end

  defp validate_base_url!(%URI{
         scheme: scheme,
         host: host,
         userinfo: nil,
         query: nil,
         fragment: nil
       })
       when scheme in ["https", "http"] and is_binary(host) and host != "",
       do: :ok

  defp validate_base_url!(_uri),
    do:
      raise(
        ArgumentError,
        "base_url must be an HTTP(S) URL without credentials, query or fragment"
      )

  defp validate_token!(nil), do: :ok
  defp validate_token!(token) when is_binary(token) and token != "", do: :ok
  defp validate_token!(provider) when is_function(provider, 0), do: :ok

  defp validate_token!(_token),
    do: raise(ArgumentError, "token must be a nonempty string or zero-arity function")

  defp validate_nonnegative!(value, _key) when is_integer(value) and value >= 0, do: :ok

  defp validate_nonnegative!(_value, key),
    do: raise(ArgumentError, "#{key} must be a nonnegative integer")

  defp validate_receive_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: :ok

  defp validate_receive_timeout!(_timeout),
    do: raise(ArgumentError, "receive_timeout must be a positive integer")

  defp validate_user_agent!(value) when is_binary(value) and value != "" do
    case String.contains?(value, ["\r", "\n"]) do
      false -> :ok
      true -> raise ArgumentError, "user_agent must be a nonempty HTTP header value"
    end
  end

  defp validate_user_agent!(_value),
    do: raise(ArgumentError, "user_agent must be a nonempty HTTP header value")

  defp validate_req_options!(options) do
    unless Keyword.keyword?(options),
      do: raise(ArgumentError, "req_options must be a keyword list")
  end
end
