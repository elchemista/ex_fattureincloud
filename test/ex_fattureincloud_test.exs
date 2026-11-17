defmodule ExFattureincloudTest do
  use ExUnit.Case, async: true
  alias ExFattureincloud.{Client, Error, User}

  test "immutable clients do not expose credentials through inspection" do
    client = Client.new(token: "super-secret", req_options: [headers: [{"x-secret", "hidden"}]])
    refute inspect(client) =~ "super-secret"
    refute inspect(client) =~ "hidden"
    assert client.base_url == "https://api-v2.fattureincloud.it"
  end

  test "invalid configuration is rejected" do
    for opts <- [
          [token: ""],
          [max_retries: -1],
          [retry_delay: -1],
          [receive_timeout: 0],
          [base_url: "file:///tmp/test"],
          [base_url: "https://u:p@example.com"],
          [base_url: "https://example.com?token=secret"],
          [typo: true],
          [user_agent: "x\r\ny"]
        ] do
      assert_raise ArgumentError, fn -> Client.new(opts) end
    end
  end

  test "missing token and failed token providers return authentication errors" do
    assert {:error, %Error{kind: :authentication}} = User.get_user_info(Client.new())
    client = Client.new(token: fn -> raise "secret exception" end)
    assert {:error, %Error{kind: :authentication} = error} = User.get_user_info(client)
    refute inspect(error) =~ "secret exception"
  end

  test "unknown operations and unsafe raw URLs are rejected locally" do
    client = Client.new(token: "token")
    assert {:error, %Error{kind: :validation}} = ExFattureincloud.call(client, "notAnOperation")

    for path <- ["https://example.com", "//example.com", "/x?token=foo", "/x#foo", "/\\evil", nil] do
      assert {:error, %Error{kind: :validation}} = ExFattureincloud.request(client, :get, path)
    end

    assert {:error, %Error{kind: :validation}} = ExFattureincloud.request(client, :connect, "/x")
  end

  test "unwrap raises the structured error" do
    assert_raise Error, "failed", fn ->
      ExFattureincloud.unwrap!({:error, %Error{message: "failed"}})
    end

    response = %ExFattureincloud.Response{status: 200, data: []}
    assert ExFattureincloud.unwrap!({:ok, response}) == response
  end

  test "OAuth scopes match the official contract and unknown scope names are identifiable" do
    specification = "priv/openapi.json" |> File.read!() |> Jason.decode!()

    official =
      get_in(specification, [
        "components",
        "securitySchemes",
        "OAuth2AuthenticationCodeFlow",
        "flows",
        "authorizationCode",
        "scopes"
      ])

    assert ExFattureincloud.Scopes.all() == official
    assert ExFattureincloud.Scopes.valid?("entity.clients:r")
    refute ExFattureincloud.Scopes.valid?("unknown:a")
    assert ExFattureincloud.Operations.get(nil) == nil
    assert ExFattureincloud.Operations.get(42) == nil
  end
end
