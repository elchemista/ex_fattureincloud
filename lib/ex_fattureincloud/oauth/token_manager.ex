defmodule ExFattureincloud.OAuth.TokenManager.State do
  @moduledoc false
  @derive {Inspect, only: [:status]}
  defstruct [
    :client,
    :load,
    :save,
    :token,
    :pending,
    :task,
    :timer,
    :error,
    oauth: [],
    waiters: [],
    status: :ready,
    retry_at: 0,
    refresh_margin: 60,
    retry_interval: 30_000,
    automatic: true
  ]

  @type t :: %__MODULE__{}
end

defmodule ExFattureincloud.OAuth.TokenManager do
  @moduledoc """
  Optional supervised OAuth refresh coordinator for one OAuth connection.

  Required options are `:client_id`, `:load` (a zero-arity callback returning
  `{:ok, %OAuth.Token{}}`) and `:save` (a callback accepting the new token and
  returning `:ok`). Set `:client_secret` for authorization-code applications;
  omit it for device-code applications. `:client` configures OAuth HTTP requests.

  `:refresh_margin` is in seconds (default 60, capped at half the token lifetime).
  `:retry_interval` is in milliseconds (default 30,000). `:automatic` defaults to
  true; disabling it keeps renewal on demand. `:name` is a GenServer name and `:id`
  optionally distinguishes supervised children.

  Refresh and persistence run in a task; concurrent callers share its result.
  New credentials are published only after `:save` succeeds. If persistence fails,
  the rotated credentials remain in memory and only saving is retried. Timeouts,
  server errors and invalid responses pause renewal because their outcome may be
  uncertain. `invalid_grant` requires authorization again. `reload/1` recovers by
  reading the application's current stored credentials.

  Use one owner per OAuth connection, even when it covers multiple companies.
  Coordination is local to this process; deployments on multiple nodes must elect
  one owner or provide distributed coordination. A process crash between remote
  renewal and successful persistence cannot restore an unsaved rotated token.
  """
  use GenServer

  alias ExFattureincloud.{Client, Error, OAuth}
  alias ExFattureincloud.OAuth.Token
  alias ExFattureincloud.OAuth.TokenManager.State

  @type server :: GenServer.server()
  @type token_result :: {:ok, String.t()} | {:error, Error.t()}
  @option_names [
    :name,
    :id,
    :client,
    :client_id,
    :client_secret,
    :load,
    :save,
    :refresh_margin,
    :retry_interval,
    :automatic
  ]

  @doc "Starts one refresh coordinator and loads its stored OAuth credentials."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    with :ok <- validate_options(options) do
      GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
    end
  end

  @doc "Supervisor child specification; :id or :name allows multiple connections."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :id, Keyword.get(options, :name, __MODULE__)),
      start: {__MODULE__, :start_link, [options]},
      shutdown: 10_000
    }
  end

  @doc "Gets a current access token, sharing any refresh already in progress."
  @spec access_token(server(), timeout()) :: token_result()
  def access_token(server, timeout \\ 30_000) do
    GenServer.call(server, :access_token, timeout)
  catch
    :exit, reason -> {:error, authentication_error(:manager_unavailable, reason)}
  end

  @doc "Builds an API client using the manager's HTTP settings and current credentials."
  @spec client(server()) :: Client.t()
  def client(server) do
    server
    |> GenServer.call(:client)
    |> Map.put(:token, fn -> access_token(server) end)
  end

  @doc "Returns status, expiry and pending-save information without credentials."
  @spec status(server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @doc "Reloads persisted credentials; refuses to discard an in-flight or unsaved token."
  @spec reload(server()) :: :ok | {:error, Error.t()}
  def reload(server), do: GenServer.call(server, :reload)

  @impl true
  @doc false
  @spec init(keyword()) :: {:ok, State.t()} | {:stop, Error.t()}
  def init(options) do
    Process.flag(:trap_exit, true)

    case load_token(options[:load]) do
      {:ok, token} ->
        state = %State{
          client: Keyword.get_lazy(options, :client, &Client.new/0),
          load: options[:load],
          save: options[:save],
          token: token,
          oauth:
            options
            |> Keyword.take([:client_id, :client_secret])
            |> Keyword.reject(fn {_, value} -> is_nil(value) end),
          refresh_margin: Keyword.get(options, :refresh_margin, 60),
          retry_interval: Keyword.get(options, :retry_interval, 30_000),
          automatic: Keyword.get(options, :automatic, true)
        }

        {:ok, schedule(state)}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  @doc false
  @spec handle_call(term(), GenServer.from(), State.t()) :: tuple()
  def handle_call(:client, _from, state), do: {:reply, state.client, state}
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:reload, _from, %State{task: %Task{}} = state),
    do: {:reply, {:error, authentication_error(:refresh_in_progress)}, state}

  def handle_call(:reload, _from, %State{pending: %Token{}} = state),
    do: {:reply, {:error, state.error}, state}

  def handle_call(:reload, _from, state) do
    case load_token(state.load) do
      {:ok, token} ->
        updated = %{state | token: token, status: :ready, error: nil, retry_at: 0}
        {:reply, :ok, updated |> cancel_timer() |> schedule()}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(:access_token, from, %State{task: %Task{}} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:access_token, from, state) do
    case next_action(state) do
      action when action in [:refresh, :save] ->
        {:noreply, state |> Map.put(:waiters, [from]) |> start_task(action)}

      :cached ->
        {:reply, available_token(state), state}
    end
  end

  @impl true
  @doc false
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info({reference, outcome}, %State{task: %Task{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, state |> Map.put(:task, nil) |> finish(outcome)}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %State{task: %Task{ref: reference}} = state
      ) do
    {:noreply,
     state
     |> Map.put(:task, nil)
     |> finish({:failed, authentication_error(:refresh_failed, reason)})}
  end

  def handle_info({:refresh_due, tag}, %State{timer: {_reference, tag}} = state) do
    state = %{state | timer: nil}
    {:noreply, advance(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @doc false
  @spec terminate(term(), State.t()) :: :ok
  def terminate(_reason, %State{task: %Task{} = task}) do
    Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  @doc false
  @spec format_status(map()) :: map()
  def format_status(%{state: state} = status) do
    status
    |> Map.put(:state, public_status(state))
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
    |> Map.replace(:reason, :redacted)
  end

  @spec advance(State.t()) :: State.t()
  defp advance(%State{task: %Task{}} = state), do: state

  defp advance(state) do
    case next_action(state) do
      action when action in [:refresh, :save] -> start_task(state, action)
      :cached -> schedule(state)
    end
  end

  @spec next_action(State.t()) :: :refresh | :save | :cached
  defp next_action(%State{pending: %Token{}} = state),
    do: if(retry_ready?(state), do: :save, else: :cached)

  defp next_action(%State{status: status})
       when status in [:reauthorization_required, :refresh_failed], do: :cached

  defp next_action(%State{status: :rate_limited} = state),
    do: if(retry_ready?(state), do: :refresh, else: :cached)

  defp next_action(state), do: if(refresh_due?(state), do: :refresh, else: :cached)

  @spec start_task(State.t(), :refresh | :save) :: State.t()
  defp start_task(state, action) do
    state = cancel_timer(state)
    task = Task.async(fn -> perform(state, action) end)
    %{state | task: task}
  end

  @spec perform(State.t(), :refresh | :save) :: tuple()
  defp perform(%State{pending: token, save: save}, :save), do: persist(save, token, :pending)

  defp perform(state, :refresh) do
    options = Keyword.put(state.oauth, :refresh_token, state.token.refresh_token)

    with {:ok, token} <- OAuth.refresh_token(state.client, options),
         {:ok, token} <- refresh_credentials(token, state.token) do
      persist(state.save, token, :refresh)
    else
      {:error, error} ->
        {:refresh_error, error}
    end
  rescue
    error -> {:failed, authentication_error(:refresh_failed, error)}
  catch
    kind, reason -> {:failed, authentication_error(:refresh_failed, {kind, reason})}
  end

  @spec refresh_credentials(Token.t(), Token.t()) :: {:ok, Token.t()} | {:error, Error.t()}
  defp refresh_credentials(%Token{refresh_token: nil} = token, previous),
    do: {:ok, %{token | refresh_token: previous.refresh_token}}

  defp refresh_credentials(%Token{refresh_token: value} = token, _previous)
       when is_binary(value) and value != "",
       do: {:ok, token}

  defp refresh_credentials(_token, _previous),
    do: {:error, %Error{kind: :protocol, message: "invalid OAuth refresh token response"}}

  @spec persist(function(), Token.t(), :pending | :refresh) :: tuple()
  defp persist(save, token, source) do
    case invoke(save, [token]) do
      :ok -> {:saved, token, source}
      failure -> {:unsaved, token, authentication_error(:persistence_failed, failure)}
    end
  end

  @spec finish(State.t(), tuple()) :: State.t()
  defp finish(state, {:saved, token, source}) do
    updated = %{state | token: token, pending: nil, status: :ready, error: nil, retry_at: 0}
    finish_saved(updated, source)
  end

  defp finish(state, {:unsaved, token, error}) do
    %{
      state
      | pending: token,
        status: :persistence_failed,
        error: error,
        retry_at: monotonic_now() + state.retry_interval
    }
    |> reply_waiters()
    |> schedule()
  end

  defp finish(state, {:refresh_error, %Error{code: "invalid_grant"} = error}),
    do: fail(state, :reauthorization_required, error)

  defp finish(state, {:refresh_error, %Error{status: status, retry_after: seconds} = error})
       when status in [403, 429] and is_integer(seconds) do
    delay = max(state.retry_interval, seconds * 1_000)

    %{
      state
      | status: :rate_limited,
        retry_at: monotonic_now() + delay,
        error: authentication_error(:rate_limited, error)
    }
    |> reply_waiters()
    |> schedule()
  end

  defp finish(state, {:refresh_error, error}), do: fail(state, :refresh_failed, error)
  defp finish(state, {:failed, error}), do: fail(state, :refresh_failed, error)

  @spec finish_saved(State.t(), :pending | :refresh) :: State.t()
  defp finish_saved(state, :pending) do
    if refresh_due?(state),
      do: start_task(state, :refresh),
      else: state |> reply_waiters() |> schedule()
  end

  defp finish_saved(state, :refresh) do
    if expired?(state.token),
      do: fail(state, :refresh_failed, :token_expired_before_use),
      else: state |> reply_waiters() |> schedule()
  end

  @spec fail(State.t(), atom(), term()) :: State.t()
  defp fail(state, status, cause) do
    %{state | status: status, error: authentication_error(status, cause)} |> reply_waiters()
  end

  @spec reply_waiters(State.t()) :: State.t()
  defp reply_waiters(state) do
    result = available_token(state)
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    %{state | waiters: []}
  end

  @spec available_token(State.t()) :: token_result()
  defp available_token(%State{pending: %Token{}, error: error}), do: {:error, error}

  defp available_token(%State{status: :reauthorization_required, error: error}),
    do: {:error, error}

  defp available_token(%State{token: token, error: error}) do
    if expired?(token),
      do: {:error, error || authentication_error(:token_expired)},
      else: {:ok, token.access_token}
  end

  @spec schedule(State.t()) :: State.t()
  defp schedule(%State{automatic: false} = state), do: state
  defp schedule(%State{task: %Task{}} = state), do: state

  defp schedule(%State{status: status} = state)
       when status in [:refresh_failed, :reauthorization_required], do: state

  defp schedule(%State{timer: {_reference, _tag}} = state), do: state

  defp schedule(state) do
    delay = timer_delay(state) |> max(1) |> min(86_400_000)
    tag = make_ref()
    reference = Process.send_after(self(), {:refresh_due, tag}, delay)
    %{state | timer: {reference, tag}}
  end

  @spec timer_delay(State.t()) :: integer()
  defp timer_delay(%State{status: status, retry_at: retry_at})
       when status in [:rate_limited, :persistence_failed],
       do: retry_at - monotonic_now()

  defp timer_delay(state),
    do:
      max(0, state.token.expires_at - effective_margin(state) - System.system_time(:second)) *
        1_000

  @spec cancel_timer(State.t()) :: State.t()
  defp cancel_timer(%State{timer: {reference, _tag}} = state) do
    Process.cancel_timer(reference)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: state

  @spec refresh_due?(State.t()) :: boolean()
  defp refresh_due?(state),
    do: state.token.expires_at <= System.system_time(:second) + effective_margin(state)

  @spec effective_margin(State.t()) :: non_neg_integer()
  defp effective_margin(%State{token: %Token{expires_in: lifetime}, refresh_margin: margin})
       when is_integer(lifetime) and lifetime > 0,
       do: min(margin, div(lifetime, 2))

  defp effective_margin(%State{refresh_margin: margin}), do: margin
  @spec expired?(Token.t()) :: boolean()
  defp expired?(%Token{expires_at: expires_at}), do: expires_at <= System.system_time(:second)
  @spec retry_ready?(State.t()) :: boolean()
  defp retry_ready?(%State{retry_at: retry_at}), do: monotonic_now() >= retry_at
  @spec monotonic_now() :: integer()
  defp monotonic_now, do: System.monotonic_time(:millisecond)

  @spec public_status(State.t()) :: map()
  defp public_status(state),
    do: %{
      status: state.status,
      expires_at: state.token.expires_at,
      pending_save?: not is_nil(state.pending)
    }

  @spec load_token(function()) :: {:ok, Token.t()} | {:error, Error.t()}
  defp load_token(load) do
    case invoke(load, []) do
      {:ok, %Token{access_token: access, refresh_token: refresh, expires_at: expires_at} = token}
      when is_binary(access) and access != "" and is_binary(refresh) and refresh != "" and
             is_integer(expires_at) ->
        {:ok, token}

      failure ->
        {:error, authentication_error(:load_failed, failure)}
    end
  end

  @spec invoke(function(), list()) :: term()
  defp invoke(callback, arguments) do
    apply(callback, arguments)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec validate_options(keyword()) :: :ok | {:error, Error.t()}
  defp validate_options(options) do
    validations = [
      is_function(options[:load], 0),
      is_function(options[:save], 1),
      is_binary(options[:client_id]) and options[:client_id] != "",
      valid_secret?(options[:client_secret]),
      is_struct(Keyword.get_lazy(options, :client, &Client.new/0), Client),
      valid_interval?(Keyword.get(options, :refresh_margin, 60)),
      valid_interval?(Keyword.get(options, :retry_interval, 30_000)),
      is_boolean(Keyword.get(options, :automatic, true)),
      Keyword.keys(options) -- @option_names == []
    ]

    if Enum.all?(validations),
      do: :ok,
      else: {:error, Error.validation("invalid OAuth token manager options")}
  end

  @spec valid_interval?(term()) :: boolean()
  defp valid_interval?(value) when is_integer(value) and value >= 0, do: true
  defp valid_interval?(_value), do: false

  @spec valid_secret?(term()) :: boolean()
  defp valid_secret?(nil), do: true
  defp valid_secret?(value) when is_binary(value) and value != "", do: true
  defp valid_secret?(_value), do: false

  @spec authentication_error(atom(), term()) :: Error.t()
  defp authentication_error(code, cause \\ nil),
    do: %Error{
      kind: :authentication,
      code: code,
      message: "OAuth token manager: #{code}",
      cause: cause
    }
end
