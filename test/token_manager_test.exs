defmodule ExFattureincloud.TokenManagerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  alias ExFattureincloud.{Error, User}
  alias ExFattureincloud.OAuth.{Token, TokenManager}

  setup do
    Req.Test.stub(__MODULE__, fn _ -> flunk("unexpected OAuth or API request") end)
    store = start_supervised!({Agent, fn -> token(3600) end})

    client =
      ExFattureincloud.new(
        base_url: "https://fic.example.com",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    %{store: store, client: client}
  end

  test "a valid stored token is reused without an OAuth request", context do
    manager = start_manager(context)

    assert {:ok, "old-access"} = TokenManager.access_token(manager)
    assert {:ok, "old-access"} = TokenManager.access_token(manager)
    assert %{pending_save?: false, expires_at: expires_at} = TokenManager.status(manager)
    assert expires_at > System.system_time(:second)
  end

  test "one refresh serves concurrent callers and persists rotated credentials", context do
    expire(context.store)
    test_process = self()

    manager =
      start_manager(context,
        save: fn refreshed ->
          Agent.update(context.store, fn _ -> refreshed end)
          send(test_process, {:saved, refreshed})
          :ok
        end
      )

    expect_refresh()

    calls = for _ <- 1..20, do: Task.async(fn -> TokenManager.access_token(manager) end)
    assert Enum.map(calls, &Task.await/1) == List.duplicate({:ok, "new-access"}, 20)
    assert_receive {:saved, %Token{access_token: "new-access", refresh_token: "new-refresh"}}
    assert Agent.get(context.store, & &1.refresh_token) == "new-refresh"
    assert TokenManager.status(manager).pending_save? == false
    Req.Test.verify!(__MODULE__)
  end

  test "status remains responsive while the OAuth HTTP task is blocked", context do
    expire(context.store)
    manager = start_manager(context)
    test_process = self()

    Req.Test.expect(__MODULE__, fn conn ->
      send(test_process, {:refresh_started, self()})

      receive do
        :continue_refresh -> refreshed_response(conn)
      after
        5000 -> raise "refresh barrier was not released"
      end
    end)

    caller = Task.async(fn -> TokenManager.access_token(manager) end)
    assert_receive {:refresh_started, worker}, 1000
    on_exit(fn -> send(worker, :continue_refresh) end)

    query = Task.async(fn -> TokenManager.status(manager) end)
    assert {:ok, %{pending_save?: false}} = Task.yield(query, 1000)
    send(worker, :continue_refresh)

    assert {:ok, "new-access"} = Task.await(caller)
    Req.Test.verify!(__MODULE__)
  end

  test "the managed client inherits the HTTP configuration and uses the refreshed token",
       context do
    expire(context.store)
    manager = start_manager(context)
    expect_refresh()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "fic.example.com"
      assert conn.request_path == "/user/info"
      assert get_req_header(conn, "authorization") == ["Bearer new-access"]
      Req.Test.json(conn, %{data: %{id: 12}})
    end)

    client = TokenManager.client(manager)
    assert client.base_url == context.client.base_url
    assert {:ok, %{data: %{"id" => 12}}} = User.get_user_info(client)
    Req.Test.verify!(__MODULE__)
  end

  test "a failed save retains the rotated token and retries persistence without another refresh",
       context do
    expire(context.store)
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :save_attempts)
    test_process = self()

    manager =
      start_manager(context,
        retry_interval: 0,
        save: fn refreshed ->
          attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
          send(test_process, {:save_attempt, attempt, refreshed.refresh_token})

          if attempt == 1 do
            {:error, :store_unavailable}
          else
            Agent.update(context.store, fn _ -> refreshed end)
            :ok
          end
        end
      )

    expect_refresh()

    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    assert %{status: :persistence_failed, pending_save?: true} = TokenManager.status(manager)
    assert Agent.get(context.store, & &1.refresh_token) == "old-refresh"
    assert {:error, %Error{kind: :authentication}} = TokenManager.reload(manager)
    assert {:ok, "new-access"} = TokenManager.access_token(manager)
    assert_receive {:save_attempt, 1, "new-refresh"}
    assert_receive {:save_attempt, 2, "new-refresh"}
    assert Agent.get(context.store, & &1.refresh_token) == "new-refresh"
    Req.Test.verify!(__MODULE__)
  end

  test "a persistence cooldown prevents write storms from concurrent API calls", context do
    expire(context.store)
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :save_attempts)

    manager =
      start_manager(context,
        retry_interval: 60_000,
        save: fn _ ->
          Agent.update(attempts, &(&1 + 1))
          {:error, :store_unavailable}
        end
      )

    expect_refresh()

    for _ <- 1..5 do
      assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    end

    assert Agent.get(attempts, & &1) == 1
    assert TokenManager.status(manager).pending_save?
    Req.Test.verify!(__MODULE__)
  end

  test "an expired pending token is persisted then refreshed using its rotated refresh token",
       context do
    expire(context.store)
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :save_attempts)

    manager =
      start_manager(context,
        retry_interval: 0,
        save: fn refreshed ->
          attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

          if attempt == 1 do
            {:error, :store_unavailable}
          else
            Agent.update(context.store, fn _ -> refreshed end)
            :ok
          end
        end
      )

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        access_token: "short-lived-access",
        refresh_token: "rotated-refresh",
        expires_in: 1
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert Jason.decode!(body)["refresh_token"] == "rotated-refresh"

      Req.Test.json(conn, %{
        access_token: "final-access",
        refresh_token: "final-refresh",
        expires_in: 86_400
      })
    end)

    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    assert TokenManager.status(manager).pending_save?
    Process.send_after(self(), :short_lived_token_expired, 1100)
    assert_receive :short_lived_token_expired, 2000

    assert {:ok, "final-access"} = TokenManager.access_token(manager)
    assert Agent.get(context.store, & &1.refresh_token) == "final-refresh"
    assert Agent.get(attempts, & &1) == 3
    Req.Test.verify!(__MODULE__)
  end

  test "save callback exceptions are contained without exposing credentials", context do
    expire(context.store)

    manager =
      start_manager(context,
        save: fn _ -> raise "storage failed with password=private-password" end
      )

    expect_refresh()

    assert {:error, %Error{kind: :authentication} = error} = TokenManager.access_token(manager)
    assert Process.alive?(manager)
    assert TokenManager.status(manager).pending_save?
    refute inspect(error) =~ "private-password"
    refute inspect(TokenManager.status(manager)) =~ "private-password"
    Req.Test.verify!(__MODULE__)
  end

  test "an omitted refresh token keeps the previous refresh token", context do
    expire(context.store)
    manager = start_manager(context)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{access_token: "new-access", expires_in: 86_400})
    end)

    assert {:ok, "new-access"} = TokenManager.access_token(manager)
    assert Agent.get(context.store, & &1.refresh_token) == "old-refresh"
    Req.Test.verify!(__MODULE__)
  end

  test "device applications refresh without a client secret", context do
    expire(context.store)
    manager = start_manager(context, client_secret: nil)

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      refute Map.has_key?(Jason.decode!(body), "client_secret")
      refreshed_response(conn)
    end)

    assert {:ok, "new-access"} = TokenManager.access_token(manager)
    Req.Test.verify!(__MODULE__)
  end

  for status <- [429, 403] do
    test "HTTP #{status} with Retry-After can recover after its cooldown", context do
      expire(context.store)
      manager = start_manager(context, retry_interval: 0)

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> put_resp_header("retry-after", "0")
        |> put_status(unquote(status))
        |> Req.Test.json(%{error: %{message: "Quota exceeded"}})
      end)

      expect_refresh()

      assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
      assert %{status: :rate_limited} = TokenManager.status(manager)
      assert {:ok, "new-access"} = TokenManager.access_token(manager)
      Req.Test.verify!(__MODULE__)
    end
  end

  test "Retry-After is not shortened by demand from other callers", context do
    expire(context.store)
    manager = start_manager(context, retry_interval: 0)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_header("retry-after", "3600")
      |> put_status(429)
      |> Req.Test.json(%{error: %{message: "Quota exceeded"}})
    end)

    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    Req.Test.verify!(__MODULE__)
  end

  test "a rate-limited refresh can continue using a token that has not actually expired",
       context do
    Agent.update(context.store, fn _ -> token(30) end)
    manager = start_manager(context)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_header("retry-after", "3600")
      |> put_status(429)
      |> Req.Test.json(%{error: %{message: "Quota exceeded"}})
    end)

    assert {:ok, "old-access"} = TokenManager.access_token(manager)
    assert %{status: :rate_limited} = TokenManager.status(manager)
    assert {:ok, "old-access"} = TokenManager.access_token(manager)
    Req.Test.verify!(__MODULE__)
  end

  test "invalid_grant requires authorization again and does not repeat refresh", context do
    expire(context.store)
    manager = start_manager(context)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_status(400)
      |> Req.Test.json(%{error: "invalid_grant", error_description: "Refresh token revoked"})
    end)

    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    assert %{status: :reauthorization_required} = TokenManager.status(manager)
    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    Req.Test.verify!(__MODULE__)

    Agent.update(context.store, fn _ -> token(3600, "external-access", "external-refresh") end)
    assert :ok = TokenManager.reload(manager)
    assert {:ok, "external-access"} = TokenManager.access_token(manager)
  end

  for status <- [500, 503] do
    test "HTTP #{status} pauses refresh instead of blindly replaying a token mutation", context do
      expire(context.store)
      manager = start_manager(context)

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> put_status(unquote(status))
        |> Req.Test.json(%{error: %{message: "Temporary failure"}})
      end)

      assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
      assert %{status: :refresh_failed} = TokenManager.status(manager)
      assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
      Req.Test.verify!(__MODULE__)
    end
  end

  test "an ambiguous transport failure is not retried by manager or managed GET", context do
    expire(context.store)
    manager = start_manager(context)
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    assert {:error, %Error{kind: :authentication}} =
             User.get_user_info(TokenManager.client(manager))

    assert %{status: :refresh_failed} = TokenManager.status(manager)
    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    Req.Test.verify!(__MODULE__)
  end

  test "a malformed successful OAuth response pauses refresh", context do
    expire(context.store)
    manager = start_manager(context)
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{unexpected: true}))

    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    assert %{status: :refresh_failed} = TokenManager.status(manager)
    assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
    Req.Test.verify!(__MODULE__)
  end

  test "a failed proactive refresh does not discard an access token that is still valid",
       context do
    Agent.update(context.store, fn _ -> token(30) end)
    manager = start_manager(context)

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> put_status(503) |> Req.Test.json(%{error: %{message: "Unavailable"}})
    end)

    assert {:ok, "old-access"} = TokenManager.access_token(manager)
    assert %{status: :refresh_failed} = TokenManager.status(manager)
    assert {:ok, "old-access"} = TokenManager.access_token(manager)
    Req.Test.verify!(__MODULE__)
  end

  test "short token lifetimes cap the refresh margin and do not refresh immediately", context do
    Agent.update(context.store, fn _ -> %{token(15) | expires_in: 20} end)
    manager = start_manager(context, refresh_margin: 60)
    assert {:ok, "old-access"} = TokenManager.access_token(manager)
  end

  test "reload observes credentials updated externally", context do
    manager = start_manager(context)
    Agent.update(context.store, fn _ -> token(3600, "external-access", "external-refresh") end)

    assert :ok = TokenManager.reload(manager)
    assert {:ok, "external-access"} = TokenManager.access_token(manager)
  end

  test "initial load failures return an error without starting a manager", context do
    Process.flag(:trap_exit, true)

    for load <- [fn -> {:error, :database_unavailable} end, fn -> {:ok, :invalid_token} end] do
      options = [
        client: context.client,
        client_id: "app",
        load: load,
        save: fn _ -> :ok end,
        automatic: false
      ]

      assert {:error, _} = TokenManager.start_link(options)
    end
  end

  test "status and system status omit credentials and callbacks", context do
    manager = start_manager(context)

    for inspected <- [inspect(TokenManager.status(manager)), inspect(:sys.get_status(manager))] do
      refute inspected =~ "old-access"
      refute inspected =~ "old-refresh"
      refute inspected =~ "client-secret"
      refute inspected =~ "#Function"
    end
  end

  test "a stopped manager becomes an authentication error in its managed client", context do
    manager = start_manager(context)
    client = TokenManager.client(manager)
    GenServer.stop(manager, :normal)

    assert {:error, %Error{kind: :authentication}} = User.get_user_info(client)
  end

  test "the proactive timer refreshes and persists without waiting for an API request", context do
    Agent.update(context.store, fn _ -> token(2) end)
    test_process = self()
    expect_refresh()

    manager =
      start_manager(context,
        automatic: true,
        refresh_margin: 0,
        save: fn refreshed ->
          Agent.update(context.store, fn _ -> refreshed end)
          send(test_process, {:proactively_saved, refreshed.access_token})
          :ok
        end
      )

    assert_receive {:proactively_saved, "new-access"}, 3000
    assert {:ok, "new-access"} = TokenManager.access_token(manager)
    Req.Test.verify!(__MODULE__)
  end

  test "manual string tokens retain the original authentication path", context do
    client = %{context.client | token: "manual-token"}

    Req.Test.expect(__MODULE__, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer manual-token"]
      Req.Test.json(conn, %{data: %{id: 5}})
    end)

    assert {:ok, %{data: %{"id" => 5}}} = User.get_user_info(client)
    Req.Test.verify!(__MODULE__)
  end

  for invalid_refresh <- ["", 12, %{"token" => "wrong"}] do
    test "invalid rotated refresh token #{inspect(invalid_refresh)} is never persisted",
         context do
      expire(context.store)
      manager = start_manager(context)

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          access_token: "new-access",
          refresh_token: unquote(Macro.escape(invalid_refresh)),
          expires_in: 86_400
        })
      end)

      assert {:error, %Error{kind: :authentication}} = TokenManager.access_token(manager)
      assert %{status: :refresh_failed, pending_save?: false} = TokenManager.status(manager)
      assert Agent.get(context.store, & &1.refresh_token) == "old-refresh"
      Req.Test.verify!(__MODULE__)
    end
  end

  test "invalid manager options are rejected before loading credentials", context do
    base = [
      client: context.client,
      client_id: "app",
      load: fn -> flunk("load must not run") end,
      save: fn _ -> :ok end
    ]

    for override <- [
          [automaticc: true],
          [client_secret: ""],
          [refresh_margin: -1],
          [retry_interval: -1]
        ] do
      assert {:error, %Error{kind: :validation}} =
               TokenManager.start_link(Keyword.merge(base, override))
    end
  end

  test "diagnostic formatting redacts task results and OTP event logs", context do
    manager = start_manager(context)

    diagnostic = %{
      state: :sys.get_state(manager),
      message: {:result, token(3600)},
      log: [{{:reply, token(3600)}, self()}],
      reason: %{secret: "client-secret"}
    }

    formatted = TokenManager.format_status(diagnostic)
    assert formatted.message == :redacted
    assert formatted.log == []
    assert formatted.reason == :redacted
    refute inspect(formatted) =~ "old-access"
    refute inspect(formatted) =~ "old-refresh"
    refute inspect(formatted) =~ "client-secret"
  end

  test "normal shutdown allows an in-flight persistence task to finish" do
    test_process = self()

    task =
      Task.async(fn ->
        receive do
          :persist -> send(test_process, :persisted_before_shutdown)
        end
      end)

    Process.send_after(task.pid, :persist, 10)
    state = %ExFattureincloud.OAuth.TokenManager.State{task: task}

    assert :ok = TokenManager.terminate(:shutdown, state)
    assert_received :persisted_before_shutdown
  end

  defp start_manager(context, overrides \\ []) do
    options = [
      client: context.client,
      client_id: "app",
      client_secret: "client-secret",
      automatic: false,
      load: fn -> {:ok, Agent.get(context.store, & &1)} end,
      save: fn refreshed ->
        Agent.update(context.store, fn _ -> refreshed end)
        :ok
      end
    ]

    manager = start_supervised!({TokenManager, Keyword.merge(options, overrides)}, id: make_ref())
    :ok = Req.Test.allow(__MODULE__, self(), manager)
    manager
  end

  defp expire(store), do: Agent.update(store, fn _ -> token(-1) end)

  defp token(seconds, access \\ "old-access", refresh \\ "old-refresh") do
    %Token{
      access_token: access,
      refresh_token: refresh,
      token_type: "bearer",
      expires_in: 86_400,
      expires_at: System.system_time(:second) + seconds
    }
  end

  defp expect_refresh do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "fic.example.com"
      assert conn.request_path == "/oauth/token"
      assert get_req_header(conn, "authorization") == []
      {:ok, body, conn} = read_body(conn)

      assert Jason.decode!(body) == %{
               "grant_type" => "refresh_token",
               "client_id" => "app",
               "client_secret" => "client-secret",
               "refresh_token" => "old-refresh"
             }

      refreshed_response(conn)
    end)
  end

  defp refreshed_response(conn) do
    Req.Test.json(conn, %{
      access_token: "new-access",
      refresh_token: "new-refresh",
      token_type: "bearer",
      expires_in: 86_400
    })
  end
end
