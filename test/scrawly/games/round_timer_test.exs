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
      assert_receive {:timer_started, %{game_id: ^game_id, duration_seconds: 80}}, 1000

      # Stop timer
      assert :ok = RoundTimer.stop_timer(game_id)

      # Should receive timer_stopped message
      assert_receive {:timer_stopped, %{game_id: ^game_id}}, 1000
    end
  end
end
