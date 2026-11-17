defmodule ExFattureincloud do
  @moduledoc """
  Elixir client for Fatture in Cloud API v2.

  Create a client with `new/1` and use the resource modules, for example
  `ExFattureincloud.Clients.list_clients/3`. Requests return
  `{:ok, %ExFattureincloud.Response{}}` or `{:error, %ExFattureincloud.Error{}}`.
  JSON keys remain strings; response envelopes and pagination are preserved.

      client = ExFattureincloud.new(token: System.fetch_env!("FIC_ACCESS_TOKEN"))
      ExFattureincloud.User.list_user_companies(client)

  Clients are immutable and have no global credentials. Optional supervised
  OAuth renewal is provided by `ExFattureincloud.OAuth.TokenManager`.
  API writes are never repeated automatically.
  """

  alias ExFattureincloud.{API, Client, Error, Response, Transport}

  @doc "Creates an immutable client. See `ExFattureincloud.Client.new/1`."
  @spec new(keyword()) :: Client.t()
  defdelegate new(options), to: Client

  @doc "Calls an operation by its snake_case atom/string or official OpenAPI operationId."
  @spec call(Client.t(), atom() | String.t(), keyword()) :: Response.result()
  defdelegate call(client, operation, options \\ []), to: API

  @doc """
  Makes a request to an API-relative path, including endpoints added after this SDK.

  Options: `:query` (map/keyword), `:body` (JSON value), `:multipart` (Req multipart
  fields), `:accept` (default `application/json`), `:authenticated` (default `true`).
  Absolute URLs are rejected.
  """
  @spec request(Client.t(), atom(), String.t(), keyword()) :: Response.result()
  defdelegate request(client, method, path, options \\ []), to: Transport

  @doc "Returns the response or raises `ExFattureincloud.Error`."
  @spec unwrap!(Response.result()) :: Response.t()
  def unwrap!({:ok, %Response{} = response}), do: response
  def unwrap!({:error, %Error{} = error}), do: raise(error)
end
