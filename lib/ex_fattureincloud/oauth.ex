defmodule ExFattureincloud.OAuth.Token do
  @moduledoc "OAuth credentials. Inspection hides access/refresh tokens. Times are Unix seconds."
  @derive {Inspect, only: [:token_type, :expires_at]}
  @enforce_keys [:access_token, :expires_at]
  defstruct [:access_token, :refresh_token, :token_type, :expires_at, :expires_in]

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          token_type: String.t(),
          expires_at: integer(),
          expires_in: pos_integer()
        }

  @doc "True if the token expires within the given safety margin (default 60 seconds)."
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, margin \\ 60),
    do: expires_at <= System.system_time(:second) + margin
end

defmodule ExFattureincloud.OAuth do
  @moduledoc """
  OAuth authorization-code, refresh-token and device-code helpers, following the
  official Go and TypeScript SDKs. JSON bodies are used, not HTTP Basic auth.

  Call `authorization_url/2` with a fresh `generate_state/0`; persist it in the
  user's server session and validate the callback with `validate_state/2` before
  exchanging the code. Tokens are returned as `OAuth.Token` structs. Save the new
  refresh token after every successful refresh. These functions do not store
  credentials; `ExFattureincloud.OAuth.TokenManager` optionally coordinates
  renewal and application-provided persistence callbacks.

  Device authorization requires provider enablement. `device_token/2` performs
  exactly one poll: schedule subsequent polls using the returned interval and
  handle `authorization_pending`/`slow_down` through `Error.code`.
  """
  alias ExFattureincloud.{Client, Error, Transport}
  alias ExFattureincloud.OAuth.Token

  @doc "Generates a cryptographically random URL-safe state value."
  @spec generate_state() :: String.t()
  def generate_state, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc "Constant-time comparison; rejects missing or empty state values."
  @spec validate_state(term(), term()) :: :ok | {:error, :invalid_state}
  def validate_state(expected, actual)
      when is_binary(expected) and is_binary(actual) and byte_size(expected) > 0 do
    if byte_size(expected) == byte_size(actual) and :crypto.hash_equals(expected, actual),
      do: :ok,
      else: {:error, :invalid_state}
  end

  def validate_state(_, _), do: {:error, :invalid_state}

  @doc "Builds the browser redirect URL. Requires client_id, redirect_uri, scope, state."
  @spec authorization_url(Client.t(), keyword()) :: String.t()
  def authorization_url(%Client{} = client, options) do
    for key <- [:client_id, :redirect_uri, :state] do
      unless is_binary(options[key]) and options[key] != "",
        do: raise(ArgumentError, "#{key} is required")
    end

    params = [
      response_type: "code",
      client_id: options[:client_id],
      redirect_uri: options[:redirect_uri],
      scope: scope_string(Keyword.fetch!(options, :scope)),
      state: options[:state]
    ]

    client.base_url <> "/oauth/authorize?" <> URI.encode_query(params)
  end

  @doc "Exchanges a code. Requires client_id, client_secret, redirect_uri, code."
  @spec exchange_code(Client.t(), keyword()) :: {:ok, Token.t()} | {:error, Error.t()}
  def exchange_code(client, options) do
    token_request(client, "authorization_code", options, [
      :client_id,
      :client_secret,
      :redirect_uri,
      :code
    ])
  end

  @doc "Refreshes tokens. Omit client_secret only for a device-code application."
  @spec refresh_token(Client.t(), keyword()) :: {:ok, Token.t()} | {:error, Error.t()}
  def refresh_token(client, options) do
    token_request(client, "refresh_token", options, [:client_id, :refresh_token], [:client_secret])
  end

  @doc "Requests a device code; accepts both enveloped and flat provider responses."
  @spec device_code(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def device_code(client, options) do
    with {:ok, fields} <- fields(options, [:client_id], []),
         {:ok, scope} <- device_scope(options),
         {:ok, response} <-
           Transport.request(client, :post, "/oauth/device",
             body: Map.put(fields, :scope, scope),
             authenticated: false,
             operation: :oauth_device
           ),
         %{"device_code" => code, "interval" => interval} = data <- response.data,
         true <- is_binary(code) and code != "" and is_integer(interval) and interval > 0 do
      {:ok, data}
    else
      {:error, _} = error -> error
      _ -> {:error, %Error{kind: :protocol, message: "invalid OAuth device response"}}
    end
  end

  @doc "Makes one device-token poll. Requires client_id and device_code."
  @spec device_token(Client.t(), keyword()) :: {:ok, Token.t()} | {:error, Error.t()}
  def device_token(client, options),
    do:
      token_request(client, "urn:ietf:params:oauth:grant-type:device_code", options, [
        :client_id,
        :device_code
      ])

  defp token_request(client, grant, options, required, optional \\ []) do
    with {:ok, body} <- fields(options, required, optional),
         {:ok, response} <-
           Transport.request(client, :post, "/oauth/token",
             body: Map.put(body, :grant_type, grant),
             authenticated: false,
             operation: :oauth_token
           ) do
      parse_token(response.data)
    end
  end

  defp fields(options, required, optional) do
    case Enum.find(required, fn key -> not is_binary(options[key]) or options[key] == "" end) do
      nil -> {:ok, options |> Keyword.take(required ++ optional) |> Map.new()}
      key -> {:error, Error.validation("OAuth parameter #{key} is required")}
    end
  end

  defp scope_string(scopes) when is_list(scopes), do: Enum.join(scopes, " ")
  defp scope_string(scope) when is_binary(scope), do: scope

  defp device_scope(options) do
    case options[:scope] do
      value when is_list(value) or is_binary(value) -> {:ok, scope_string(value)}
      _ -> {:error, Error.validation("OAuth parameter scope is required")}
    end
  end

  defp parse_token(%{"access_token" => access, "expires_in" => expires} = data)
       when is_binary(access) and access != "" and is_integer(expires) and expires > 0 do
    {:ok,
     %Token{
       access_token: access,
       refresh_token: data["refresh_token"],
       token_type: data["token_type"] || "bearer",
       expires_in: expires,
       expires_at: System.system_time(:second) + expires
     }}
  end

  defp parse_token(_),
    do: {:error, %Error{kind: :protocol, message: "invalid OAuth token response"}}
end
