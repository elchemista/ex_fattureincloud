defmodule ExFattureincloud.WebhookTest do
  use ExUnit.Case, async: true
  alias ExFattureincloud.Webhook

  setup do
    private = :public_key.generate_key({:namedCurve, :secp256r1})
    public = {{:ECPoint, elem(private, 4)}, elem(private, 3)}
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)])

    claims = %{
      "iss" => "https://api-v2.fattureincloud.it",
      "aud" => ["https://example.com/webhook"],
      "aid" => 123,
      "iat" => System.system_time(:second),
      "exp" => System.system_time(:second) + 3600,
      "jti" => "event-1",
      "sub" => "company:7"
    }

    opts = [audience: "https://example.com/webhook", application_id: 123, public_key: pem]
    %{private: private, claims: claims, opts: opts}
  end

  test "verifies ES256 signature and required claims", %{private: key, claims: claims, opts: opts} do
    assert {:ok, ^claims} = Webhook.verify(sign(key, claims), opts)

    assert {:ok, ^claims} =
             Webhook.verify(sign(key, claims), Keyword.put(opts, :application_id, "123"))
  end

  test "rejects expired, future, issuer, audience, app, event and subject mismatches", %{
    private: key,
    claims: claims,
    opts: opts
  } do
    for change <- [
          %{"exp" => System.system_time(:second) - 60},
          %{"iat" => System.system_time(:second) + 120},
          %{"iss" => "https://evil.example.com"},
          %{"aud" => ["https://another-target.example.com"]},
          %{"aid" => 999},
          %{"exp" => nil},
          %{"nbf" => System.system_time(:second) + 120}
        ] do
      assert {:error, :invalid_claims} =
               Webhook.verify(sign(key, Map.merge(claims, change)), opts)
    end

    assert {:error, :invalid_claims} =
             Webhook.verify(sign(key, claims), Keyword.put(opts, :event_id, "other"))

    assert {:error, :invalid_claims} =
             Webhook.verify(sign(key, claims), Keyword.put(opts, :subject, "company:8"))
  end

  test "rejects tampering, different keys, algorithm confusion and malformed input", %{
    private: key,
    claims: claims,
    opts: opts
  } do
    other = :public_key.generate_key({:namedCurve, :secp256r1})
    assert {:error, :invalid_signature} = Webhook.verify(sign(other, claims), opts)
    assert {:error, :invalid_signature} = Webhook.verify(sign(key, claims, "none"), opts)

    for token <- [
          nil,
          "",
          "Bearer invalid",
          "Bearer a.b.c",
          "Bearer " <> String.duplicate("a", 20)
        ] do
      assert {:error, :invalid_signature} = Webhook.verify(token, opts)
    end

    ["Bearer " <> h, _, sig] = String.split(sign(key, claims), ".")
    changed_payload = encode(Map.put(claims, "aid", 999))

    assert {:error, :invalid_signature} =
             Webhook.verify("Bearer #{h}.#{changed_payload}.#{sig}", opts)
  end

  test "structured and binary events bind jti and sub", %{
    private: key,
    claims: claims,
    opts: opts
  } do
    auth = sign(key, claims)

    event = %{
      "id" => "event-1",
      "subject" => "company:7",
      "type" => "example",
      "data" => %{"ids" => [12]}
    }

    assert {:ok, ^event} = Webhook.verify_event([{"Authorization", auth}], event, opts)

    assert {:error, :invalid_claims} =
             Webhook.verify_event(
               %{"authorization" => auth},
               %{event | "id" => "different"},
               opts
             )

    headers = %{
      "authorization" => [auth],
      "ce-id" => "event-1",
      "ce-subject" => "company:7",
      "ce-type" => "example"
    }

    assert {:ok, %{"id" => "event-1", "data" => %{"ids" => [12]}}} =
             Webhook.verify_event(headers, %{"ids" => [12]}, opts)
  end

  test "verification challenge response and malformed events" do
    assert Webhook.verification_response("challenge") == %{"verification" => "challenge"}
    assert {:error, :invalid_event} = Webhook.verify_event(%{}, %{}, [])
    assert {:error, :invalid_event} = Webhook.verify_event(%{}, "invalid", [])
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp sign(private, claims, alg \\ "ES256") do
    input = encode(%{alg: alg, typ: "JWT"}) <> "." <> encode(claims)
    der = :public_key.sign(input, :sha256, private)
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

    "Bearer " <>
      input <>
      "." <> Base.url_encode64(<<r::unsigned-size(256), s::unsigned-size(256)>>, padding: false)
  end
end
