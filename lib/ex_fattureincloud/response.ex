defmodule ExFattureincloud.Response do
  @moduledoc """
  A successful HTTP response. `body` preserves the complete API envelope;
  `data` is its `\"data\"` field, or the raw body for XML/plain text responses.
  `pagination` contains the pagination fields returned by the server.
  """
  alias ExFattureincloud.RateLimit
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

  @doc false
  def from_req(%Req.Response{} = response) do
    body = response.body

    %__MODULE__{
      status: response.status,
      body: body,
      data: if(is_map(body), do: Map.get(body, "data", body), else: body),
      headers: response.headers,
      rate_limit: RateLimit.from_headers(response.headers),
      pagination:
        if(is_map(body),
          do:
            Map.take(
              body,
              ~w(current_page last_page per_page total from to first_page_url last_page_url next_page_url prev_page_url path)
            ),
          else: %{}
        )
    }
  end
end
