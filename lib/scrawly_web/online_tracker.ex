defmodule ScrawlyWeb.OnlineTracker do
  @moduledoc """
  The header's "N online": the distinct visitors seen in the last 45 s, on
  any page.

  A visitor is a `ScrawlyWeb.Auth.actor_key/1`: the user id, or a hash of an
  account-less session's id, so several tabs of one user or session count
  once. AppLayout touches the key when it renders and from its
  `:presence_ping` command, which every open tab sends every 20 s. Entries
  not touched for 45 s (the TTL) are dropped by a sweep every 10 s, so a
  closed tab leaves the count 25-55 s after it closed.

  Whenever the count changes it is broadcast on the `:online` Hologram
  Realtime channel as `:online_count_updated` (`%{count: n}`), at most once
  per 5 s: changes inside that window go out together, as the latest value,
  when it ends.

  Rooms ask it which of their members still have a live tab
  (`live_keys/2`, see `Scrawly.Games.RoomServer`'s presence sweep).

  Node-local (like Hologram.PubSub, unless the nodes are clustered). Hologram
  has no presence API or disconnect hook, hence the heartbeat.

  Options (for tests): `:name` (`nil` for an unnamed process), `:clock` (a
  0-arity fun returning monotonic ms), `:broadcast` (a 1-arity fun given the
  new count), `:ttl_ms`, `:sweep_ms`, `:coalesce_ms`.
  """
  use GenServer

  @ttl_ms 45_000
  @sweep_ms 10_000
  @coalesce_ms 5_000

  @doc "The Realtime channel AppLayout subscribes to for the count."
  @spec channel() :: :online
  def channel, do: :online

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Marks `key` as seen now. A `nil` key is ignored."
  @spec touch(GenServer.server(), term) :: :ok
  def touch(server \\ __MODULE__, key)
  def touch(_server, nil), do: :ok
  def touch(server, key), do: GenServer.cast(server, {:touch, key})

  @doc """
  The current count. Ordered after the caller's own earlier `touch/2`s. 0 when
  the tracker isn't running.
  """
  @spec count(GenServer.server()) :: non_neg_integer
  def count(server \\ __MODULE__) do
    GenServer.call(server, :count)
  catch
    :exit, _ -> 0
  end

  @doc """
  `{:ok, set}` of those of `keys` seen within the TTL (a live tab), or
  `:error` when the tracker isn't running or doesn't answer within 1 s: a
  caller must then assume nothing about its keys. Ordered after the
  caller's own earlier `touch/2`s.
  """
  @spec live_keys(GenServer.server(), [term]) :: {:ok, MapSet.t()} | :error
  def live_keys(server \\ __MODULE__, keys) when is_list(keys) do
    GenServer.call(server, {:live_keys, keys}, 1_000)
  catch
    :exit, _ -> :error
  end

  @doc "How long a key counts without a touch, in ms."
  @spec ttl_ms() :: pos_integer
  def ttl_ms, do: @ttl_ms

  # Server callbacks

  @impl true
  def init(opts) do
    state = %{
      seen: %{},
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      broadcast: Keyword.get(opts, :broadcast, &broadcast_count/1),
      ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
      sweep_ms: Keyword.get(opts, :sweep_ms, @sweep_ms),
      coalesce_ms: Keyword.get(opts, :coalesce_ms, @coalesce_ms),
      # The count the last broadcast carried (clients start from count/0 in
      # AppLayout.init) and when it went out.
      sent_count: 0,
      sent_at: nil,
      flush_pending?: false
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:touch, key}, state) do
    new? = not Map.has_key?(state.seen, key)
    state = %{state | seen: Map.put(state.seen, key, state.clock.())}
    {:noreply, if(new?, do: maybe_broadcast(state), else: state)}
  end

  @impl true
  def handle_call(:count, _from, state), do: {:reply, map_size(state.seen), state}

  # By the TTL itself, not by the last sweep (which can be up to sweep_ms
  # behind).
  def handle_call({:live_keys, keys}, _from, state) do
    cutoff = state.clock.() - state.ttl_ms

    live =
      keys
      |> Enum.filter(fn key ->
        case Map.fetch(state.seen, key) do
          {:ok, at} -> at >= cutoff
          :error -> false
        end
      end)
      |> MapSet.new()

    {:reply, {:ok, live}, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep(state)
    cutoff = state.clock.() - state.ttl_ms
    seen = Map.filter(state.seen, fn {_key, at} -> at >= cutoff end)

    if map_size(seen) == map_size(state.seen),
      do: {:noreply, state},
      else: {:noreply, maybe_broadcast(%{state | seen: seen})}
  end

  def handle_info(:flush, state) do
    state = %{state | flush_pending?: false}

    if map_size(state.seen) == state.sent_count,
      do: {:noreply, state},
      else: {:noreply, send_count(state)}
  end

  # A change goes out now unless one went out less than coalesce_ms ago; then
  # a single :flush at the end of that window sends whatever the count is by
  # then (nothing if it is back to the value last sent).
  defp maybe_broadcast(state) do
    cond do
      state.flush_pending? or map_size(state.seen) == state.sent_count ->
        state

      state.sent_at == nil or state.clock.() - state.sent_at >= state.coalesce_ms ->
        send_count(state)

      true ->
        wait = state.sent_at + state.coalesce_ms - state.clock.()
        Process.send_after(self(), :flush, wait)
        %{state | flush_pending?: true}
    end
  end

  defp send_count(state) do
    count = map_size(state.seen)
    state.broadcast.(count)
    %{state | sent_count: count, sent_at: state.clock.()}
  end

  defp broadcast_count(count),
    do: Hologram.Realtime.broadcast_action(channel(), :online_count_updated, %{count: count})

  defp schedule_sweep(state), do: Process.send_after(self(), :sweep, state.sweep_ms)
end
