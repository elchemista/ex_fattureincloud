defmodule ExFattureincloud.Response do
  @moduledoc """
  A successful HTTP response. `body` preserves the complete API envelope;
  `data` is its `\"data\"` field, or the raw body for XML/plain text responses.
  `pagination` contains the pagination fields returned by the server.
  """
  alias ExFattureincloud.RateLimit

  @pagination_fields ~w(
    current_page last_page per_page total from to first_page_url last_page_url
    next_page_url prev_page_url path
  )
  defstruct [:status, :body, :data, :rate_limit, headers: %{}, pagination: %{}]

  @type t :: %__MODULE__{
          status: integer(),
          body: term(),
          data: term(),
          headers: map(),
          pagination: map(),
          rate_limit: RateLimit.t()
        }
  @type result :: {:ok, t()} | {:error, ExFattureincloud.Error.t()}

  @doc "Converts a successful Req response, preserving its envelope, pagination and quota headers."
  @spec from_req(Req.Response.t()) :: t()
  def from_req(%Req.Response{} = response) do
    body = response.body

    %__MODULE__{
      status: response.status,
      body: body,
      data: response_data(body),
      headers: response.headers,
      rate_limit: RateLimit.from_headers(response.headers),
      pagination: pagination(body)
    }
  end

  defp response_data(%{"data" => data}), do: data
  defp response_data(body), do: body

  defp pagination(%{} = body), do: Map.take(body, @pagination_fields)
  defp pagination(_body), do: %{}
end
