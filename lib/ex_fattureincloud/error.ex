defmodule ExFattureincloud.Error do
  @moduledoc """
  Normalized validation, authentication, transport, HTTP or protocol error.

  API validation details remain in `body`. `code` also handles OAuth string errors
  such as `authorization_pending`. `retry_after` is in seconds. `cause` preserves
  the transport exception. Inspect excludes body, headers and cause.
  """
  @derive {Inspect, only: [:kind, :status, :code, :message, :retry_after]}
  defexception [
    :kind,
    :status,
    :code,
    :body,
    :cause,
    :retry_after,
    :rate_limit,
    message: "Fatture in Cloud request failed",
    headers: %{}
  ]

  @type t :: %__MODULE__{
          kind: atom(),
          status: integer() | nil,
          code: term(),
          body: term(),
          cause: term(),
          retry_after: integer() | nil,
          message: String.t(),
          headers: map(),
          rate_limit: ExFattureincloud.RateLimit.t() | nil
        }

  @doc "Builds a local parameter-validation error without an HTTP status."
  @spec validation(String.t()) :: t()
  def validation(message), do: %__MODULE__{kind: :validation, message: message}

  @doc "Converts an unsuccessful Req response while preserving its body and quota headers."
  @spec from_req(Req.Response.t()) :: t()
  def from_req(%Req.Response{} = response) do
    limit = ExFattureincloud.RateLimit.from_headers(response.headers)
    {code, message} = details(response.body, response.status)

    %__MODULE__{
      kind: :http,
      status: response.status,
      body: response.body,
      headers: response.headers,
      code: code,
      message: message,
      rate_limit: limit,
      retry_after: limit.retry_after
    }
  end

  defp details(%{"error" => %{} = error}, status),
    do: {error["code"], string_message(error["message"], status)}

  defp details(%{"error" => code} = body, status) when is_binary(code),
    do: {code, string_message(body["error_description"] || code, status)}

  defp details(_, status), do: {nil, "Fatture in Cloud returned HTTP #{status}"}
  defp string_message(value, _) when is_binary(value), do: value
  defp string_message(_, status), do: "Fatture in Cloud returned HTTP #{status}"
end
