defmodule ExFattureincloud.Webhook do
  @moduledoc """
  Webhook verification using the provider's ES256 public key and JWT claims.

  `verify/2` requires the target URL as `:audience` and the Fatture in Cloud app ID
  as `:application_id`. `:event_id` and `:subject` optionally bind claims to an
  event; `verify_event/3` checks both automatically for binary/structured events.
  `:public_key` accepts a trusted PEM for key rotation. `:clock_skew` defaults to
  30 seconds. The published key is pinned; update it if the provider rotates it.

  Authenticate verification GETs before echoing `verification_response/1` with
  HTTP 200. Deduplicate POST notifications by their event ID in your application;
  provider delivery is at least once and can be out of order. JWT verification
  authenticates provider claims; it is not a digest of the HTTP request body.
  """
  @key Base.decode64!(
         "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUZrd0V3WUhLb1pJemowQ0FRWUlLb1pJemowREFRY0RRZ0FFL1JvSElqZ1k3aGZYZlk1cC9KeStLL0ZndU1aNAozVHZaOXQ0ZU43K2t4UTBNSnpLdG93djRDY1lURnFyQm03aE1CNVpXS25xTHoyNEQ2bFFqU0wwWXN3PT0KLS0tLS1FTkQgUFVCTElDIEtFWS0tLS0tCg=="
       )
  @issuer "https://api-v2.fattureincloud.it"

  @doc "Verifies signature, algorithm, issuer, audience, app ID and token times."
  @spec verify(term(), keyword()) :: {:ok, map()} | {:error, :invalid_claims | :invalid_signature}
  def verify(authorization, options) when is_binary(authorization) do
    audience = Keyword.fetch!(options, :audience)
    app_id = Keyword.fetch!(options, :application_id)
    skew = Keyword.get(options, :clock_skew, 30)
    now = System.system_time(:second)

    with [_, token] <- Regex.run(~r/\ABearer ([^\s]+)\z/i, authorization),
         [header, payload, signature] <- String.split(token, "."),
         {:ok, %{"alg" => "ES256"}} <- decode_json(header),
         {:ok, claims} when is_map(claims) <- decode_json(payload),
         {:ok, <<r::unsigned-size(256), s::unsigned-size(256)>>} <-
           Base.url_decode64(signature, padding: false),
         true <- verify_signature(header <> "." <> payload, r, s, options[:public_key] || @key),
         :ok <- validate_claims(claims, audience, app_id, now, skew, options) do
      {:ok, claims}
    else
      {:error, :invalid_claims} = error -> error
      _ -> {:error, :invalid_signature}
    end
  end

  def verify(_, _), do: {:error, :invalid_signature}

  @doc "Verifies an event and checks JWT jti/sub against the event ID/subject."
  @spec verify_event(map() | list(), term(), keyword()) ::
          {:ok, map()} | {:error, :invalid_claims | :invalid_signature | :invalid_event}
  def verify_event(headers, body, options) when is_map(body) do
    headers
    |> normalize_headers()
    |> authenticate_notification(body, options)
  end

  def verify_event(_, _, _), do: {:error, :invalid_event}

  @doc "Body to return with HTTP 200 for an authenticated verification challenge."
  @spec verification_response(String.t()) :: map()
  def verification_response(challenge) when is_binary(challenge) and challenge != "",
    do: %{"verification" => challenge}

  @spec decode_json(String.t()) :: {:ok, term()} | {:error, Jason.DecodeError.t()} | :error
  defp decode_json(segment) do
    with {:ok, bytes} <- Base.url_decode64(segment, padding: false), do: Jason.decode(bytes)
  end

  @spec verify_signature(String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          boolean()
  defp verify_signature(input, r, s, pem) do
    [entry] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)
    signature = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :public_key.verify(input, :sha256, signature, key)
  rescue
    _ -> false
  end

  @spec validate_claims(
          map(),
          String.t(),
          String.t() | integer(),
          integer(),
          integer(),
          keyword()
        ) ::
          :ok | {:error, :invalid_claims}
  defp validate_claims(
         %{
           "iss" => @issuer,
           "aud" => audiences,
           "aid" => app_id,
           "exp" => expiry,
           "iat" => issued_at
         } =
           claims,
         audience,
         expected_app_id,
         now,
         skew,
         options
       )
       when is_integer(expiry) and is_integer(issued_at) and
              (is_binary(app_id) or is_integer(app_id)) do
    with true <- audience in List.wrap(audiences),
         true <- to_string(app_id) == to_string(expected_app_id),
         true <- valid_lifetime?(expiry, issued_at, now, skew),
         true <- valid_not_before?(claims["nbf"], now + skew),
         true <- matches_optional?(claims["jti"], options[:event_id]),
         true <- matches_optional?(claims["sub"], options[:subject]) do
      :ok
    else
      false -> {:error, :invalid_claims}
    end
  end

  defp validate_claims(_, _, _, _, _, _), do: {:error, :invalid_claims}

  @spec valid_lifetime?(integer(), integer(), integer(), integer()) :: boolean()
  defp valid_lifetime?(expiry, issued_at, now, skew)
       when expiry > now - skew and issued_at <= now + skew and issued_at < expiry,
       do: true

  defp valid_lifetime?(_, _, _, _), do: false

  @spec valid_not_before?(term(), integer()) :: boolean()
  defp valid_not_before?(nil, _), do: true
  defp valid_not_before?(not_before, latest) when is_integer(not_before), do: not_before <= latest
  defp valid_not_before?(_, _), do: false

  @spec matches_optional?(term(), term()) :: boolean()
  defp matches_optional?(_, nil), do: true
  defp matches_optional?(actual, expected), do: actual == expected

  @spec authenticate_notification(map(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  defp authenticate_notification(headers, body, options) do
    headers
    |> notification(body)
    |> authenticate_event(headers["authorization"], options)
  end

  @spec notification(map(), map()) :: map()
  defp notification(%{"ce-id" => id} = headers, body) do
    %{
      "id" => id,
      "subject" => headers["ce-subject"],
      "type" => headers["ce-type"],
      "source" => headers["ce-source"],
      "time" => headers["ce-time"],
      "specversion" => headers["ce-specversion"],
      "data" => body
    }
  end

  defp notification(_, body), do: body

  @spec authenticate_event(map(), term(), keyword()) :: {:ok, map()} | {:error, atom()}
  defp authenticate_event(%{"id" => id, "subject" => subject} = event, authorization, options)
       when is_binary(id) and is_binary(subject) do
    options = options |> Keyword.put(:event_id, id) |> Keyword.put(:subject, subject)

    with {:ok, _} <- verify(authorization, options), do: {:ok, event}
  end

  defp authenticate_event(_, _, _), do: {:error, :invalid_event}

  @spec normalize_headers(map() | list()) :: map()
  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} ->
      {String.downcase(to_string(key)), value |> List.wrap() |> List.first()}
    end)
  end
end
