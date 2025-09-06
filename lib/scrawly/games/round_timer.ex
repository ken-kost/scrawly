defmodule Scrawly.Games.RoundTimer do
  @moduledoc """
  GenServer that manages 80-second round timers for games.

  Each game can have one active timer that counts down from 80 seconds.
  When the timer expires, it broadcasts a round_ended event via Phoenix PubSub.
  """
  use GenServer

  # 80 seconds in milliseconds
  @round_duration_ms 80_000
  # Send updates every 1 second
  @tick_interval_ms 1_000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a timer for a specific game.
  """
  def start_timer(game_id) do
    GenServer.call(__MODULE__, {:start_timer, game_id})
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
  def handle_call({:start_timer, game_id}, _from, state) do
    # Cancel existing timer if any
    state = cancel_timer_if_exists(state, game_id)

    # Start new timer
    timer_ref = Process.send_after(self(), {:tick, game_id}, @tick_interval_ms)
    start_time = System.monotonic_time(:millisecond)

    timer_info = %{
      timer_ref: timer_ref,
      start_time: start_time,
      remaining_ms: @round_duration_ms
    }

    new_timers = Map.put(state.timers, game_id, timer_info)

    # Broadcast timer started
    Phoenix.PubSub.broadcast(
      Scrawly.PubSub,
      "game:#{game_id}",
      {:timer_started, %{game_id: game_id, duration_seconds: div(@round_duration_ms, 1000)}}
    )

    {:reply, :ok, %{state | timers: new_timers}}
  end

  @impl true
  def handle_call({:stop_timer, game_id}, _from, state) do
    new_state = cancel_timer_if_exists(state, game_id)

    # Broadcast timer stopped
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
        timer_info -> max(0, div(timer_info.remaining_ms, 1000))
      end

    {:reply, remaining_seconds, state}
  end

  @impl true
  def handle_call(:get_active_timers, _from, state) do
    active_timers =
      state.timers
      |> Enum.map(fn {game_id, timer_info} ->
        {game_id, div(timer_info.remaining_ms, 1000)}
      end)
      |> Enum.into(%{})

    {:reply, active_timers, state}
  end

  @impl true
  def handle_info({:tick, game_id}, state) do
    case Map.get(state.timers, game_id) do
      nil ->
        # Timer was cancelled, ignore
        {:noreply, state}

      timer_info ->
        current_time = System.monotonic_time(:millisecond)
        elapsed_ms = current_time - timer_info.start_time
        remaining_ms = max(0, @round_duration_ms - elapsed_ms)

        if remaining_ms <= 0 do
          # Timer expired
          new_timers = Map.delete(state.timers, game_id)

          # Broadcast round ended
          Phoenix.PubSub.broadcast(
            Scrawly.PubSub,
            "game:#{game_id}",
            {:round_ended, %{game_id: game_id, reason: :time_up}}
          )

          {:noreply, %{state | timers: new_timers}}
        else
          # Continue ticking
          updated_timer_info = %{timer_info | remaining_ms: remaining_ms}
          timer_ref = Process.send_after(self(), {:tick, game_id}, @tick_interval_ms)
          updated_timer_info = %{updated_timer_info | timer_ref: timer_ref}

          new_timers = Map.put(state.timers, game_id, updated_timer_info)

          # Broadcast timer update every 10 seconds or in final 10 seconds
          remaining_seconds = div(remaining_ms, 1000)

          if rem(remaining_seconds, 10) == 0 or remaining_seconds <= 10 do
            Phoenix.PubSub.broadcast(
              Scrawly.PubSub,
              "game:#{game_id}",
              {:timer_update, %{game_id: game_id, remaining_seconds: remaining_seconds}}
            )
          end

          {:noreply, %{state | timers: new_timers}}
        end
    end
  end

  # Private functions

  defp cancel_timer_if_exists(state, game_id) do
    case Map.get(state.timers, game_id) do
      nil ->
        state

      timer_info ->
        Process.cancel_timer(timer_info.timer_ref)
        new_timers = Map.delete(state.timers, game_id)
        %{state | timers: new_timers}
    end
  end
end
