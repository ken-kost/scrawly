defmodule Scrawly.Games.RoomServerAuthzTest do
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.RoomServer

  @creator "creator-id"
  @player "player-id"

  defp room(attrs \\ []) do
    struct!(
      %RoomServer{
        creator_id: @creator,
        status: :lobby,
        game_id: nil,
        players: [%{id: @creator, username: "c"}, %{id: @player, username: "p"}]
      },
      attrs
    )
  end

  describe "authorize/3 :start_game" do
    test "allows the creator in a lobby with 2+ players" do
      assert RoomServer.authorize(room(), @creator, :start_game) == :ok
    end

    test "rejects anyone but the creator" do
      assert RoomServer.authorize(room(), @player, :start_game) == {:error, :not_creator}
      assert RoomServer.authorize(room(), "stranger", :start_game) == {:error, :not_creator}
      assert RoomServer.authorize(room(), nil, :start_game) == {:error, :not_creator}
    end

    test "rejects outside the lobby or while a game exists" do
      for status <- [:playing, :post_game, :ended] do
        assert RoomServer.authorize(room(status: status), @creator, :start_game) ==
                 {:error, :wrong_state}
      end

      assert RoomServer.authorize(room(game_id: "g1"), @creator, :start_game) ==
               {:error, :wrong_state}
    end

    test "rejects fewer than 2 players" do
      solo = room(players: [%{id: @creator, username: "c"}])
      assert RoomServer.authorize(solo, @creator, :start_game) == {:error, :not_enough_players}

      assert RoomServer.authorize(room(players: []), @creator, :start_game) ==
               {:error, :not_enough_players}
    end

    test "works on the public map returned by get_state/1" do
      public = Map.from_struct(room())
      assert RoomServer.authorize(public, @creator, :start_game) == :ok
    end
  end

  describe "authorize/3 :dissolve" do
    test "only the creator may dissolve" do
      assert RoomServer.authorize(room(), @creator, :dissolve) == :ok
      assert RoomServer.authorize(room(), @player, :dissolve) == {:error, :not_creator}
      assert RoomServer.authorize(room(), nil, :dissolve) == {:error, :not_creator}
    end
  end

  describe "authorize/3 :leave" do
    test "players and the creator may leave" do
      assert RoomServer.authorize(room(), @player, :leave) == :ok
      assert RoomServer.authorize(room(), @creator, :leave) == :ok
    end

    test "the creator may leave even when no longer listed as a player" do
      assert RoomServer.authorize(room(players: []), @creator, :leave) == :ok
    end

    test "strangers may not" do
      assert RoomServer.authorize(room(), "stranger", :leave) == {:error, :not_member}
      assert RoomServer.authorize(room(), nil, :leave) == {:error, :not_member}
    end
  end

  describe "RoomServer process" do
    setup do
      creator = create_user()
      player = create_user()
      room = start_room(creator)
      {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})
      %{creator: creator, player: player, room: room}
    end

    test "leave/2 rejects non-members without a chat message", %{room: room} do
      before = room_state!(room.id)

      assert RoomServer.leave(room.id, "stranger") == {:error, :not_member}

      after_state = room_state!(room.id)
      assert after_state.version == before.version
      assert after_state.chat_messages == before.chat_messages
      assert after_state.players == before.players
    end

    test "dissolve_room/2 rejects anyone but the creator", %{room: room, player: player} do
      assert RoomServer.dissolve_room(room.id, player.id) == {:error, :not_creator}
      assert RoomServer.room_exists?(room.id)
    end

    test "dissolve_room/2 stops the room for the creator", %{room: room, creator: creator} do
      assert RoomServer.dissolve_room(room.id, creator.id) == :ok
      assert_room_stopped(room.id)
    end

    test "start_game/3 rejects a non-creator and leaves no Game row", %{
      room: room,
      player: player
    } do
      assert RoomServer.start_game(room.id, player.id, %{}) == {:error, :not_creator}
      assert games_for_room(room) == []
      assert room_state!(room.id).status == :lobby
    end

    test "start_game/3 takes the drawer from the room and refuses a second start", %{
      room: room,
      creator: creator
    } do
      assert {:ok, state} = RoomServer.start_game(room.id, creator.id, %{word_choices: ["a"]})
      assert state.current_drawer_id == creator.id
      assert state.total_rounds == 2
      # the reply is the public view: the choices only reach the drawer's view
      refute Map.has_key?(state, :word_choices)
      assert {:ok, %{word_choices: ["a"]}} = RoomServer.get_view(room.id, creator.id)
      assert [_game] = games_for_room(room)

      assert RoomServer.start_game(room.id, creator.id, %{}) == {:error, :wrong_state}
      assert [_game] = games_for_room(room)
    end

    test "leave_watcher/2 posts nothing for unknown ids", %{room: room} do
      before = room_state!(room.id)

      assert {:ok, _} = RoomServer.leave_watcher(room.id, "nobody")

      after_state = room_state!(room.id)
      assert after_state.version == before.version
      assert after_state.chat_messages == before.chat_messages
    end

    test "join_as_watcher/2 caps watchers at 50", %{room: room} do
      for i <- 1..50 do
        assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: "w#{i}", username: "w#{i}"})
      end

      assert RoomServer.join_as_watcher(room.id, %{id: "w51", username: "w51"}) ==
               {:error, :room_full}

      # someone already watching is still accepted
      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: "w1", username: "w1"})
      assert length(room_state!(room.id).watchers) == 50
    end
  end
end
