defmodule ExFattureincloud.OAuthTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias ExFattureincloud.{Error, OAuth}
  alias ExFattureincloud.OAuth.Token

  setup do
    %{
      client:
        ExFattureincloud.new(
          req_options: [plug: {Req.Test, __MODULE__}, headers: [{"authorization", "stale"}]]
        )
    }
  end

  test "authorization redirect encodes scopes and exact redirect URI", %{client: client} do
    state = OAuth.generate_state()

    uri =
      OAuth.authorization_url(client,
        client_id: "app",
        redirect_uri: "https://example.com/callback?env=test",
        scope: ["entity.clients:r", "settings:a"],
        state: state
      )
      |> URI.parse()

    assert uri.path == "/oauth/authorize"

    assert URI.decode_query(uri.query) == %{
             "client_id" => "app",
             "response_type" => "code",
             "redirect_uri" => "https://example.com/callback?env=test",
             "scope" => "entity.clients:r settings:a",
             "state" => state
           }

    assert :ok = OAuth.validate_state(state, state)
    assert {:error, :invalid_state} = OAuth.validate_state(state, "wrong")
    assert {:error, :invalid_state} = OAuth.validate_state(nil, nil)
    assert {:error, :invalid_state} = OAuth.validate_state("", "")
    assert OAuth.generate_state() != state
  end

  test "code exchange uses official JSON fields and never a bearer header", %{client: client} do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/oauth/token"
      assert get_req_header(conn, "authorization") == []
      {:ok, bytes, conn} = read_body(conn)

      assert Jason.decode!(bytes) == %{
               "grant_type" => "authorization_code",
               "client_id" => "app",
               "client_secret" => "secret",
               "redirect_uri" => "https://example.com/cb",
               "code" => "code"
             }

      Req.Test.json(conn, %{
        access_token: "access-secret",
        refresh_token: "refresh-secret",
        token_type: "bearer",
        expires_in: 86_400
      })
    end)

    assert {:ok, %Token{} = token} =
             OAuth.exchange_code(client,
               client_id: "app",
               client_secret: "secret",
               redirect_uri: "https://example.com/cb",
               code: "code"
             )

    assert token.expires_at in (System.system_time(:second) + 86_399)..(System.system_time(
                                                                          :second
                                                                        ) +
                                                                          86_400)

    refute Token.expired?(token)
    refute inspect(token) =~ "access-secret"
    refute inspect(token) =~ "refresh-secret"
  end

  test "refresh rotates access and refresh token and includes the secret", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, bytes, conn} = read_body(conn)

      assert Jason.decode!(bytes) == %{
               "grant_type" => "refresh_token",
               "client_id" => "app",
               "client_secret" => "secret",
               "refresh_token" => "old"
             }

      Req.Test.json(conn, %{
        access_token: "new-access",
        refresh_token: "new-refresh",
        expires_in: 86_400
      })
    end)

    assert {:ok, %{refresh_token: "new-refresh"}} =
             OAuth.refresh_token(client,
               client_id: "app",
               client_secret: "secret",
               refresh_token: "old"
             )
  end

  for enveloped <- [false, true] do
    test "device response supports enveloped=#{enveloped}, matching SDKs and docs", %{
      client: client
    } do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/oauth/device"
        {:ok, bytes, conn} = read_body(conn)
        assert Jason.decode!(bytes) == %{"client_id" => "app", "scope" => "settings:r"}
        body = %{device_code: "device", user_code: "1234", interval: 5, expires_in: 300}
        Req.Test.json(conn, if(unquote(enveloped), do: %{data: body}, else: body))
      end)

      assert {:ok, %{"device_code" => "device", "interval" => 5}} =
               OAuth.device_code(client, client_id: "app", scope: ["settings:r"])
    end
  end

  for code <- [
        "authorization_pending",
        "slow_down",
        "access_denied",
        "expired_token",
        "invalid_grant"
      ] do
    test "OAuth error #{code} is preserved, one poll only", %{client: client} do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, bytes, conn} = read_body(conn)

        assert Jason.decode!(bytes) == %{
                 "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
                 "client_id" => "app",
                 "device_code" => "device"
               }

        conn
        |> put_status(400)
        |> Req.Test.json(%{error: unquote(code), error_description: "Provider description"})
      end)

      assert {:error, %Error{code: unquote(code), message: "Provider description"}} =
               OAuth.device_token(client, client_id: "app", device_code: "device")

      Req.Test.verify!(__MODULE__)
    end
  end

  test "device refresh omits client secret", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, bytes, conn} = read_body(conn)
      refute Map.has_key?(Jason.decode!(bytes), "client_secret")

      Req.Test.json(conn, %{
        data: %{access_token: "access", refresh_token: "refresh", expires_in: 86_400}
      })
    end)

    assert {:ok, %Token{}} =
             OAuth.refresh_token(client, client_id: "app", refresh_token: "refresh")
  end

  test "malformed token and missing local fields are structured errors", %{client: client} do
    assert {:error, %Error{kind: :validation}} = OAuth.exchange_code(client, client_id: "app")
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{access_token: "missing-expiry"}))

    assert {:error, %Error{kind: :protocol}} =
             OAuth.device_token(client, client_id: "app", device_code: "code")

    assert Token.expired?(%Token{
             access_token: "token",
             expires_at: System.system_time(:second) - 1
           })
  end
end
