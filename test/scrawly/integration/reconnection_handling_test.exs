defmodule Scrawly.Integration.ReconnectionHandlingTest do
  use Scrawly.DataCase

  alias Scrawly.Games
  alias Scrawly.Accounts.User

  # Note: Room-level PubSub actions (start_game, end_game, handle_player_disconnect)
  # cannot be tested directly because the PubSub module is configured as a process name
  # rather than a module with broadcast/3. These tests focus on the User-level and
  # Game-level state transitions that underpin reconnection behavior.

  describe "reconnection handling during active game" do
    setup do
      {:ok, existing} = Games.get_all_words()
      Enum.each(existing, fn w -> Ash.destroy!(w) end)
      Scrawly.Games.Word.seed_words()

      players =
        for i <- 1..3 do
          Ash.create!(
            User,
            %{email: "recon-p#{i}-#{System.unique_integer([:positive])}@test.com"},
            authorize?: false
          )
        end

      {:ok, room} =
        Games.create_room(%{
          max_players: 6,
          name: "Reconnect Test",
          creator_id: List.first(players).id
        })

      for p <- players do
        p
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update!()
      end

      # Start a game (using Game resource directly, bypassing Room PubSub)
      {:ok, game} = Games.create_game(room.id, 5)
      {:ok, game} = Games.start_round(game.id, List.first(players).id)

      %{room: room, players: players, game: game}
    end

    test "player disconnect updates player_state to :disconnected", %{players: [_, p2, _]} do
      {:ok, connected_user} = Ash.get(User, p2.id)
      assert connected_user.player_state == :connected
      assert connected_user.current_room_id != nil

      # Disconnect via leave_room
      {:ok, disconnected_user} =
        connected_user
        |> Ash.Changeset.for_update(:leave_room, %{})
        |> Ash.update()

      assert disconnected_user.player_state == :disconnected
      assert disconnected_user.current_room_id == nil
      assert disconnected_user.score == 0
    end

    test "game continues for remaining players after one disconnects", %{
      players: [_drawer, p2, p3],
      game: game
    } do
      # p2 disconnects (leave_room on User level)
      {:ok, p2_fresh} = Ash.get(User, p2.id)
      {:ok, _} = p2_fresh |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()

      # Game is still in progress — game state is independent of user state
      {:ok, current_game} = Games.get_game_by_id(game.id)
      assert current_game.status == :in_progress
      assert current_game.current_word != nil

      # Remaining players can still advance rounds
      {:ok, _} = Games.complete_round(game.id)
      {:ok, _} = Games.next_round(game.id)
      {:ok, next_round} = Games.start_round(game.id, p3.id)
      assert next_round.current_drawer_id == p3.id
      assert next_round.current_word != nil
    end

    test "player reconnects by re-joining room via User action", %{
      room: room,
      players: [_, p2, _]
    } do
      {:ok, p2_fresh} = Ash.get(User, p2.id)

      # Disconnect
      {:ok, disconnected} =
        p2_fresh
        |> Ash.Changeset.for_update(:leave_room, %{})
        |> Ash.update()

      assert disconnected.player_state == :disconnected
      assert disconnected.current_room_id == nil

      # Reconnect via User's join_room
      {:ok, reconnected} =
        disconnected
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      assert reconnected.player_state == :connected
      assert reconnected.current_room_id == room.id
    end

    test "reconnected player can read current game state", %{
      room: room,
      players: [_, p2, _],
      game: game
    } do
      {:ok, p2_fresh} = Ash.get(User, p2.id)

      # Disconnect and reconnect
      {:ok, disc} = p2_fresh |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()

      {:ok, _recon} =
        disc |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id}) |> Ash.update()

      # After reconnection, simulate what GamePage.init does
      {:ok, current_room} = Games.get_room_by_id(room.id)
      assert current_room != nil
      # reconnected player is back
      assert length(current_room.players) >= 2

      # Game state is still available
      {:ok, current_game} = Games.get_game_by_id(game.id)
      assert current_game.status == :in_progress
      assert current_game.current_word != nil
      assert current_game.current_drawer_id != nil
      assert current_game.current_round >= 1

      # Reconnected player can determine their role (GamePage sets is_drawer)
      is_drawer = current_game.current_drawer_id == p2.id
      # p2 was not the drawer (p1 was), so they should see hints not the word
      refute is_drawer
    end

    test "disconnected drawer does not prevent round completion", %{
      players: [drawer, p2, _p3],
      game: game
    } do
      # Current drawer is p1
      assert game.current_drawer_id == drawer.id

      # Drawer disconnects
      {:ok, drawer_fresh} = Ash.get(User, drawer.id)
      {:ok, _} = drawer_fresh |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()

      # Round can still be completed programmatically
      {:ok, completed} = Games.complete_round(game.id)
      assert completed.current_word == nil

      # Next round can start with a different drawer
      {:ok, _} = Games.next_round(game.id)
      {:ok, next} = Games.start_round(game.id, p2.id)
      assert next.current_drawer_id == p2.id
      assert next.current_word != nil
    end

    test "score is reset on leave_room", %{
      room: room,
      players: [_, p2, _]
    } do
      {:ok, p2_fresh} = Ash.get(User, p2.id)

      # Give p2 some score
      {:ok, scored} =
        p2_fresh
        |> Ash.Changeset.for_update(:update_score, %{score: 500})
        |> Ash.update()

      assert scored.score == 500

      # Disconnect — score resets to 0
      {:ok, disconnected} =
        scored
        |> Ash.Changeset.for_update(:leave_room, %{})
        |> Ash.update()

      assert disconnected.score == 0

      # Reconnect — score remains 0
      {:ok, reconnected} =
        disconnected
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      assert reconnected.score == 0
    end

    test "player_state transitions: connected → disconnected → connected → drawing → guessing", %{
      room: room,
      players: [_, p2, _]
    } do
      {:ok, p2_fresh} = Ash.get(User, p2.id)
      assert p2_fresh.player_state == :connected

      # Disconnect
      {:ok, disc} = p2_fresh |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()
      assert disc.player_state == :disconnected

      # Reconnect
      {:ok, recon} =
        disc |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id}) |> Ash.update()

      assert recon.player_state == :connected

      # Set to drawing
      {:ok, drawing} =
        recon
        |> Ash.Changeset.for_update(:set_player_state, %{player_state: :drawing})
        |> Ash.update()

      assert drawing.player_state == :drawing

      # Set to guessing
      {:ok, guessing} =
        drawing
        |> Ash.Changeset.for_update(:set_player_state, %{player_state: :guessing})
        |> Ash.update()

      assert guessing.player_state == :guessing
    end

    test "multiple players disconnect and reconnect independently", %{
      room: room,
      players: [p1, p2, p3],
      game: game
    } do
      # p2 and p3 both disconnect
      {:ok, p2_fresh} = Ash.get(User, p2.id)
      {:ok, p3_fresh} = Ash.get(User, p3.id)

      {:ok, p2_disc} = p2_fresh |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()
      {:ok, p3_disc} = p3_fresh |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()

      assert p2_disc.player_state == :disconnected
      assert p3_disc.player_state == :disconnected

      # Game still in progress
      {:ok, g} = Games.get_game_by_id(game.id)
      assert g.status == :in_progress

      # p2 reconnects first
      {:ok, p2_recon} =
        p2_disc
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      assert p2_recon.player_state == :connected

      # p3 reconnects later
      {:ok, p3_recon} =
        p3_disc
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      assert p3_recon.player_state == :connected

      # All three are back in the room
      {:ok, loaded_room} = Games.get_room_by_id(room.id)
      room_player_ids = MapSet.new(loaded_room.players, & &1.id)
      assert MapSet.member?(room_player_ids, p1.id)
      assert MapSet.member?(room_player_ids, p2.id)
      assert MapSet.member?(room_player_ids, p3.id)
    end

    test "game can end normally after reconnection", %{
      room: room,
      players: [_p1, p2, _p3],
      game: game
    } do
      {:ok, p2_fresh} = Ash.get(User, p2.id)

      # p2 disconnects and reconnects
      {:ok, disc} = p2_fresh |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()

      {:ok, _recon} =
        disc |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id}) |> Ash.update()

      # Game can still end normally
      {:ok, _} = Games.complete_round(game.id)
      {:ok, ended} = Games.end_current_game(game.id)
      assert ended.status == :completed
    end
  end
end
