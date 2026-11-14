defmodule Scrawly.Games.RoomServerChatPayloadTest do
  @moduledoc """
  Chat lines reach every browser in the room, through room state
  (`chat_messages`) and the `:chat_appended` broadcast, so they must be plain
  data: an integer `timestamp` (Unix ms), no struct at any depth.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.RoomServer
  alias Scrawly.Games.RoomServer.{GameFlow, View}

  @moduletag :capture_log

  @drawer "drawer-id"
  @p1 "p1-id"

  defp room_state(attrs \\ []) do
    struct!(
      %RoomServer{
        room_id: "TEST-room-#{System.unique_integer([:positive])}",
        status: :playing,
        creator_id: @drawer,
        max_players: 4,
        game_id: "TEST-game-#{System.unique_integer([:positive])}",
        phase: :drawing,
        current_round: 1,
        total_rounds: 2,
        current_drawer_id: @drawer,
        current_word: "zzyzx",
        round_active: true,
        round_deadline: System.monotonic_time(:millisecond) + 60_000,
        round_duration: 60,
        players: [
          %{id: @drawer, username: "Drawer", score: 0},
          %{id: @p1, username: "P1", score: 0}
        ],
        round_start_scores: %{@drawer => 0, @p1 => 0}
      },
      attrs
    )
  end

  defp subscribe(room_id) do
    Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room_id}))
  end

  defp assert_plain_line(msg) do
    assert struct_free?(msg)
    assert is_integer(msg.timestamp)
    now = System.system_time(:millisecond)
    assert msg.timestamp > now - 60_000 and msg.timestamp <= now
    assert is_integer(msg.id)
  end

  test "struct_free?/1 finds structs at any depth" do
    assert struct_free?(%{a: [1, {:ok, %{b: "x"}}], c: :atom})
    refute struct_free?(%{a: [1, {:ok, %{b: DateTime.utc_now()}}]})
    refute struct_free?([%{%URI{} => 1}])
  end

  test "GameFlow.add_sys_msg/3 stores and broadcasts a plain line" do
    state = room_state()
    subscribe(state.room_id)

    for type <- [:system, :correct_guess] do
      state = GameFlow.add_sys_msg(state, "TEST line", type)

      assert [msg | _] = state.chat_messages
      assert_plain_line(msg)
      assert %{player_name: "System", message: "TEST line", type: ^type} = msg

      assert_received {:broadcast_action, _, :chat_appended, payload, _}
      # The line's id is its broadcast seq.
      assert payload == %{message: msg, seq: msg.id}
      assert msg.id == state.seq
      assert struct_free?(payload)
    end
  end

  test "a player's chat line (submit_message) is stored and broadcast as plain data" do
    state = room_state()
    subscribe(state.room_id)

    {:reply, {:ok, :chat}, state} =
      RoomServer.handle_call({:submit_message, @p1, "TEST hello"}, {self(), make_ref()}, state)

    assert [msg] = state.chat_messages
    assert_plain_line(msg)
    assert %{player_id: @p1, player_name: "P1", message: "TEST hello", type: :chat} = msg

    assert_received {:broadcast_action, _, :chat_appended, payload, _}
    assert payload == %{message: msg, seq: msg.id}
    assert struct_free?(payload)
  end

  test "a correct guess's lines are plain data too" do
    state = room_state()
    subscribe(state.room_id)

    {:reply, {:ok, {:correct, _}}, state} =
      RoomServer.handle_call({:submit_message, @p1, "zzyzx"}, {self(), make_ref()}, state)

    assert state.chat_messages != []
    Enum.each(state.chat_messages, &assert_plain_line/1)
    assert struct_free?(View.for_viewer(state, @p1))
  end

  test "a live room's chat, view and replies stay struct-free" do
    creator = create_user()
    player = create_user()
    room = start_room(creator)
    {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})
    start_drawing!(room, creator)

    assert {:ok, :chat} = RoomServer.submit_message(room.id, player.id, "TEST live hello")
    assert :ok = RoomServer.system_message(room.id, "TEST AI status")

    state = room_state!(room.id)
    assert length(state.chat_messages) >= 3
    Enum.each(state.chat_messages, &assert_plain_line/1)
    assert struct_free?(state)

    {:ok, view} = RoomServer.get_view(room.id, player.id)
    assert struct_free?(view)
  end
end
