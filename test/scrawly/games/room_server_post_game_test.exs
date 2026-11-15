defmodule Scrawly.Games.RoomServerPostGameTest do
  @moduledoc """
  The post-game window: both end-of-game paths store a monotonic deadline,
  `get_state/1` exposes only the ms left (`post_game_remaining_ms`), and a
  RoomServer restarted while the DB says `:post_game` gets a fresh window.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.RoomServer

  @moduletag :capture_log

  setup do
    creator = create_user()
    player = create_user()
    room = start_room(creator)
    {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})

    %{room: room, creator: creator, player: player}
  end

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp start_game!(room, creator) do
    {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"]})
    started
  end

  defp assert_full_window(remaining) do
    assert is_integer(remaining)
    assert remaining > RoomServer.post_game_ms() - 2_000
    assert remaining <= RoomServer.post_game_ms()
  end

  test "post_game_ms/0 is the 30 s window" do
    assert RoomServer.post_game_ms() == 30_000
  end

  test "nil outside :post_game", %{room: room, creator: creator} do
    assert room_state!(room.id).post_game_remaining_ms == nil

    start_game!(room, creator)
    assert %{status: :playing, post_game_remaining_ms: nil} = room_state!(room.id)
  end

  test "end_game sets it; :return_to_lobby clears it", %{room: room, creator: creator} do
    start_game!(room, creator)
    {:ok, ended} = RoomServer.end_game(room.id)

    assert ended.status == :post_game
    assert_full_window(ended.post_game_remaining_ms)
    assert_full_window(room_state!(room.id).post_game_remaining_ms)

    # Only the ms left is sent, never the node-local deadline.
    refute Map.has_key?(ended, :post_game_deadline)
    assert is_integer(:sys.get_state(pid_of(room)).post_game_deadline)

    send(pid_of(room), :return_to_lobby)

    assert %{status: :lobby, post_game_remaining_ms: nil} = room_state!(room.id)
    assert :sys.get_state(pid_of(room)).post_game_deadline == nil
    assert reload_room!(room).status == :lobby
  end

  test "counts down from the stored deadline", %{room: room, creator: creator} do
    start_game!(room, creator)
    {:ok, _} = RoomServer.end_game(room.id)

    :sys.replace_state(pid_of(room), &%{&1 | post_game_deadline: &1.post_game_deadline - 10_000})
    remaining = room_state!(room.id).post_game_remaining_ms
    assert remaining > 18_000 and remaining <= 20_000

    :sys.replace_state(pid_of(room), &%{&1 | post_game_deadline: &1.post_game_deadline - 60_000})
    assert room_state!(room.id).post_game_remaining_ms == 0
  end

  test "the automatic end of the last round sets it", %{room: room, creator: creator} do
    started = start_game!(room, creator)
    pid = pid_of(room)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | current_round: state.total_rounds,
          phase: :round_end,
          round_active: false
      }
    end)

    send(pid, :auto_advance_round)

    state = room_state!(room.id)
    assert state.status == :post_game
    assert state.last_game_id == started.game_id
    assert_full_window(state.post_game_remaining_ms)
    assert reload_room!(room).status == :post_game
  end

  test "a RoomServer restarted in :post_game gets a fresh window", %{room: room} do
    old_pid = pid_of(room)
    kill_room!(room)
    {:ok, _} = Games.set_room_post_game(room.id)

    assert {:ok, pid} = RoomServer.ensure_started(room.id)
    assert pid != old_pid

    state = room_state!(room.id)
    assert state.status == :post_game
    assert_full_window(state.post_game_remaining_ms)

    # The scheduled :return_to_lobby takes it back like after a normal game.
    send(pid_of(room), :return_to_lobby)
    assert %{status: :lobby, post_game_remaining_ms: nil} = room_state!(room.id)
    assert reload_room!(room).status == :lobby
  end

  test "a RoomServer restarted in the lobby has no deadline", %{room: room} do
    kill_room!(room)

    assert {:ok, pid} = RoomServer.ensure_started(room.id)
    assert :sys.get_state(pid).post_game_deadline == nil
    assert room_state!(room.id).post_game_remaining_ms == nil
  end
end
