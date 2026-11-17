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
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
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
  @spec verify_event(map() | list(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def verify_event(headers, body, options) when is_map(body) do
    headers = normalize_headers(headers)

    event =
      if Map.has_key?(headers, "ce-id") do
        %{
          "id" => headers["ce-id"],
          "subject" => headers["ce-subject"],
          "type" => headers["ce-type"],
          "source" => headers["ce-source"],
          "time" => headers["ce-time"],
          "specversion" => headers["ce-specversion"],
          "data" => body
        }
      else
        body
      end

    if is_binary(event["id"]) and is_binary(event["subject"]) do
      opts =
        options |> Keyword.put(:event_id, event["id"]) |> Keyword.put(:subject, event["subject"])

      with {:ok, _} <- verify(headers["authorization"], opts), do: {:ok, event}
    else
      {:error, :invalid_event}
    end
  end

  def verify_event(_, _, _), do: {:error, :invalid_event}

  @doc "Body to return with HTTP 200 for an authenticated verification challenge."
  @spec verification_response(String.t()) :: map()
  def verification_response(challenge) when is_binary(challenge) and challenge != "",
    do: %{"verification" => challenge}

  defp decode_json(segment) do
    with {:ok, bytes} <- Base.url_decode64(segment, padding: false), do: Jason.decode(bytes)
  end

  defp verify_signature(input, r, s, pem) do
    [entry] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)
    signature = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :public_key.verify(input, :sha256, signature, key)
  rescue
    _ -> false
  end

  defp validate_claims(c, audience, app_id, now, skew, options) do
    valid =
      c["iss"] == @issuer and audience in List.wrap(c["aud"]) and
        is_integer(c["exp"]) and c["exp"] > now - skew and
        is_integer(c["iat"]) and c["iat"] <= now + skew and c["iat"] < c["exp"] and
        (is_nil(c["nbf"]) or (is_integer(c["nbf"]) and c["nbf"] <= now + skew)) and
        (is_binary(c["aid"]) or is_integer(c["aid"])) and to_string(c["aid"]) == to_string(app_id) and
        (is_nil(options[:event_id]) or c["jti"] == options[:event_id]) and
        (is_nil(options[:subject]) or c["sub"] == options[:subject])

    if valid, do: :ok, else: {:error, :invalid_claims}
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} ->
      {String.downcase(to_string(key)), value |> List.wrap() |> List.first()}
    end)
  end
end
