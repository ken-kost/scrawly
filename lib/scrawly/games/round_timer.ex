defmodule Scrawly.Games.RoundTimer do
  @moduledoc """
  One-shot round expiry per game.

  `start_timer/3` schedules a single `{:expire, game_id, token}` message for
  the end of the round; nothing ticks in between. Clients count down from the
  remaining ms the room sends them (`RoomServer.View`), and hint reveals are
  scheduled by the room itself.

  On expiry it broadcasts `{:round_ended, meta ++ %{game_id, reason: :time_up}}`
  on Scrawly.PubSub `"game:<id>"`. Each timer carries a fresh token, so an
  expiry already in the mailbox when its timer was stopped or replaced is
  ignored and cannot end the replacement.
  """
  use GenServer

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts (or replaces) the timer for `game_id`: `duration_seconds` from now
  it broadcasts `{:round_ended, Map.merge(meta, %{game_id: game_id, reason:
  :time_up})}`. Pass the round in `meta` (`%{round: n}`) so the room can
  ignore an expiry meant for another round.
  """
  def start_timer(game_id, duration_seconds \\ 60, meta \\ %{}) do
    GenServer.call(__MODULE__, {:start_timer, game_id, duration_seconds, Map.new(meta)})
  end

  @doc """
  Stop the timer for a specific game.
  """
  def stop_timer(game_id) do
    GenServer.call(__MODULE__, {:stop_timer, game_id})
  end

  @doc """
  Get the remaining time for a game's timer.
  Returns time in seconds, or nil if no timer is running.
  """
  def get_remaining_time(game_id) do
    GenServer.call(__MODULE__, {:get_remaining_time, game_id})
  end

  @doc """
  Get all active timers (for debugging/monitoring).
  """
  def get_active_timers do
    GenServer.call(__MODULE__, :get_active_timers)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{timers: %{}}}
  end

  @impl true
  def handle_call({:start_timer, game_id, duration_seconds, meta}, _from, state) do
    state = cancel_timer_if_exists(state, game_id)
    duration_ms = round(duration_seconds * 1000)
    token = make_ref()

    timer_info = %{
      timer_ref: Process.send_after(self(), {:expire, game_id, token}, duration_ms),
      token: token,
      start_time: System.monotonic_time(:millisecond),
      duration_ms: duration_ms,
      meta: meta
    }

    Phoenix.PubSub.broadcast(
      Scrawly.PubSub,
      "game:#{game_id}",
      {:timer_started, %{game_id: game_id, duration_seconds: duration_seconds}}
    )

    {:reply, :ok, %{state | timers: Map.put(state.timers, game_id, timer_info)}}
  end

  @impl true
  def handle_call({:stop_timer, game_id}, _from, state) do
    new_state = cancel_timer_if_exists(state, game_id)

    Phoenix.PubSub.broadcast(
      Scrawly.PubSub,
      "game:#{game_id}",
      {:timer_stopped, %{game_id: game_id}}
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_remaining_time, game_id}, _from, state) do
    remaining_seconds =
      case Map.get(state.timers, game_id) do
        nil -> nil
        timer_info -> remaining_seconds(timer_info)
      end

    {:reply, remaining_seconds, state}
  end

  @impl true
  def handle_call(:get_active_timers, _from, state) do
    active_timers =
      Map.new(state.timers, fn {game_id, timer_info} ->
        {game_id, remaining_seconds(timer_info)}
      end)

    {:reply, active_timers, state}
  end

  @impl true
  def handle_info({:expire, game_id, token}, state) do
    case Map.get(state.timers, game_id) do
      %{token: ^token, meta: meta} ->
        Phoenix.PubSub.broadcast(
          Scrawly.PubSub,
          "game:#{game_id}",
          {:round_ended, Map.merge(meta, %{game_id: game_id, reason: :time_up})}
        )

        {:noreply, %{state | timers: Map.delete(state.timers, game_id)}}

      # Stopped or replaced after this expiry was sent.
      _ ->
        {:noreply, state}
    end
  end

  # Private functions

  defp remaining_seconds(timer_info) do
    elapsed_ms = System.monotonic_time(:millisecond) - timer_info.start_time
    max(0, div(timer_info.duration_ms - elapsed_ms, 1000))
  end

  defp cancel_timer_if_exists(state, game_id) do
    case Map.get(state.timers, game_id) do
      nil ->
        state

      timer_info ->
        Process.cancel_timer(timer_info.timer_ref)
        %{state | timers: Map.delete(state.timers, game_id)}
    end
  end
end
