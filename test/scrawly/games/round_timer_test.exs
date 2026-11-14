defmodule Scrawly.Games.RoundTimerTest do
  use ExUnit.Case, async: false

  alias Scrawly.Games.RoundTimer

  describe "round timer functionality" do
    test "starts and stops timers correctly" do
      game_id = "test-game-1"

      # Start timer
      assert :ok = RoundTimer.start_timer(game_id)

      # Check timer is running
      remaining = RoundTimer.get_remaining_time(game_id)
      assert is_integer(remaining)
      assert remaining > 0
      assert remaining <= 80

      # Stop timer
      assert :ok = RoundTimer.stop_timer(game_id)

      # Check timer is stopped
      assert nil == RoundTimer.get_remaining_time(game_id)
    end

    test "tracks multiple timers independently" do
      game_id1 = "test-game-1"
      game_id2 = "test-game-2"

      # Start both timers
      assert :ok = RoundTimer.start_timer(game_id1)
      assert :ok = RoundTimer.start_timer(game_id2)

      # Both should be running
      assert is_integer(RoundTimer.get_remaining_time(game_id1))
      assert is_integer(RoundTimer.get_remaining_time(game_id2))

      # Stop first timer
      assert :ok = RoundTimer.stop_timer(game_id1)

      # First should be stopped, second still running
      assert nil == RoundTimer.get_remaining_time(game_id1)
      assert is_integer(RoundTimer.get_remaining_time(game_id2))

      # Stop second timer
      assert :ok = RoundTimer.stop_timer(game_id2)
      assert nil == RoundTimer.get_remaining_time(game_id2)
    end

    test "replacing existing timer works correctly" do
      game_id = "test-game-1"

      # Start timer
      assert :ok = RoundTimer.start_timer(game_id)
      first_remaining = RoundTimer.get_remaining_time(game_id)

      # Wait a bit
      Process.sleep(100)

      # Start new timer (should replace the old one)
      assert :ok = RoundTimer.start_timer(game_id)
      second_remaining = RoundTimer.get_remaining_time(game_id)

      # New timer should have full time
      assert second_remaining >= first_remaining
    end

    test "get_active_timers returns correct information" do
      game_id1 = "test-game-1"
      game_id2 = "test-game-2"

      # No timers initially
      #  assert %{} == RoundTimer.get_active_timers()

      # Start first timer
      assert :ok = RoundTimer.start_timer(game_id1)
      active_timers = RoundTimer.get_active_timers()
      assert Map.has_key?(active_timers, game_id1)
      assert is_integer(active_timers[game_id1])

      # Start second timer
      assert :ok = RoundTimer.start_timer(game_id2)
      active_timers = RoundTimer.get_active_timers()
      assert Map.has_key?(active_timers, game_id1)
      assert Map.has_key?(active_timers, game_id2)
      assert map_size(active_timers) == 2

      # Stop first timer
      assert :ok = RoundTimer.stop_timer(game_id1)
      active_timers = RoundTimer.get_active_timers()
      refute Map.has_key?(active_timers, game_id1)
      assert Map.has_key?(active_timers, game_id2)
      assert map_size(active_timers) == 1
    end
  end

  describe "pubsub integration" do
    test "subscribing to game events receives timer messages" do
      game_id = "test-game-pubsub"

      # Subscribe to the game's PubSub topic
      Phoenix.PubSub.subscribe(Scrawly.PubSub, "game:#{game_id}")

      # Start timer
      assert :ok = RoundTimer.start_timer(game_id)

      # Should receive timer_started message
      assert_receive {:timer_started, %{game_id: ^game_id, duration_seconds: 60}}, 1000

      # Stop timer
      assert :ok = RoundTimer.stop_timer(game_id)

      # Should receive timer_stopped message
      assert_receive {:timer_stopped, %{game_id: ^game_id}}, 1000
    end
  end

  describe "one-shot expiry" do
    setup do
      game_id = "test-game-expiry-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Scrawly.PubSub, "game:#{game_id}")
      on_exit(fn -> RoundTimer.stop_timer(game_id) end)
      %{game_id: game_id}
    end

    test "delivers {:round_ended, ...} once, with the meta it was started with", %{game_id: id} do
      assert :ok = RoundTimer.start_timer(id, 0.05, %{round: 3})

      assert_receive {:round_ended, %{game_id: ^id, round: 3, reason: :time_up}}, 1_000
      refute_receive {:round_ended, _}, 200
      refute_received {:timer_update, _}
      assert nil == RoundTimer.get_remaining_time(id)
    end

    test "holds one pending message per running game", %{game_id: id} do
      other = id <> "-other"
      on_exit(fn -> RoundTimer.stop_timer(other) end)

      assert :ok = RoundTimer.start_timer(id, 60, %{round: 1})
      %{timer_ref: first_ref} = timer(id)
      assert :ok = RoundTimer.start_timer(id, 60, %{round: 2})
      assert :ok = RoundTimer.start_timer(other, 60)

      # The replaced timer's expiry was cancelled; nothing else is scheduled.
      assert Process.read_timer(first_ref) == false
      assert is_integer(Process.read_timer(timer(id).timer_ref))

      assert {:message_queue_len, 0} =
               Process.info(Process.whereis(RoundTimer), :message_queue_len)

      active = RoundTimer.get_active_timers()
      assert active[id] in 59..60
      assert active[other] in 59..60
    end

    test "a stale token cannot end a replacement timer", %{game_id: id} do
      assert :ok = RoundTimer.start_timer(id, 60, %{round: 1})
      %{token: old_token} = timer(id)
      assert :ok = RoundTimer.start_timer(id, 60, %{round: 2})

      # An expiry of the replaced timer that was already in the mailbox.
      send(RoundTimer, {:expire, id, old_token})

      assert %{meta: %{round: 2}} = timer(id)
      refute_receive {:round_ended, _}, 100
      assert is_integer(RoundTimer.get_remaining_time(id))
    end

    test "a stopped timer's expiry is ignored", %{game_id: id} do
      assert :ok = RoundTimer.start_timer(id, 60, %{round: 1})
      %{token: token} = timer(id)
      assert :ok = RoundTimer.stop_timer(id)

      send(RoundTimer, {:expire, id, token})

      refute_receive {:round_ended, _}, 100
      assert nil == RoundTimer.get_remaining_time(id)
    end
  end

  defp timer(game_id), do: :sys.get_state(RoundTimer).timers |> Map.fetch!(game_id)
end
