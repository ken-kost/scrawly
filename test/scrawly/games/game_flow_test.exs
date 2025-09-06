defmodule Scrawly.Games.GameFlowTest do
  use Scrawly.DataCase

  alias Scrawly.Games
  alias Scrawly.Accounts.User

  describe "game flow management" do
    setup do
      # Create a room
      {:ok, room} = Games.create_room(%{max_players: 4})

      # Create test players
      {:ok, player1} =
        Ash.create(User, %{username: "player1", email: "p1@test.com"}, authorize?: false)

      {:ok, player2} =
        Ash.create(User, %{username: "player2", email: "p2@test.com"}, authorize?: false)

      {:ok, player3} =
        Ash.create(User, %{username: "player3", email: "p3@test.com"}, authorize?: false)

      # Join players to room
      {:ok, _} =
        player1
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      {:ok, _} =
        player2
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      {:ok, _} =
        player3
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      # Seed words for testing
      Scrawly.Games.Word.seed_words()

      %{
        room: room,
        players: [player1, player2, player3],
        player_queue: [player1.id, player2.id, player3.id]
      }
    end

    test "create_game starts a new game with proper defaults", %{room: room} do
      assert {:ok, game} = Games.create_game(room.id, 5)
      assert game.room_id == room.id
      assert game.total_rounds == 5
      assert game.current_round == 1
      assert game.status == :in_progress
      assert game.current_word == nil
      assert game.current_drawer_id == nil
    end

    test "start_round sets a random word and drawer", %{room: room, players: [player1 | _]} do
      {:ok, game} = Games.create_game(room.id, 3)

      assert {:ok, updated_game} = Games.start_round(game.id, player1.id)
      assert updated_game.current_word != nil
      assert is_binary(updated_game.current_word)
      assert String.length(updated_game.current_word) > 0
      assert updated_game.current_drawer_id == player1.id
    end

    test "select_next_drawer rotates through player queue", %{
      room: room,
      player_queue: player_queue
    } do
      {:ok, game} = Games.create_game(room.id, 3)

      # Start with first player
      {:ok, game} = Games.start_round(game.id, Enum.at(player_queue, 0))
      assert game.current_drawer_id == Enum.at(player_queue, 0)

      # Select next drawer
      {:ok, game} = Games.select_next_drawer(game.id, player_queue)
      assert game.current_drawer_id == Enum.at(player_queue, 1)

      # Select next drawer again
      {:ok, game} = Games.select_next_drawer(game.id, player_queue)
      assert game.current_drawer_id == Enum.at(player_queue, 2)

      # Should wrap around to first player
      {:ok, game} = Games.select_next_drawer(game.id, player_queue)
      assert game.current_drawer_id == Enum.at(player_queue, 0)
    end

    test "next_round increments round number", %{room: room} do
      {:ok, game} = Games.create_game(room.id, 5)
      assert game.current_round == 1

      {:ok, updated_game} = Games.next_round(game.id)
      assert updated_game.current_round == 2

      {:ok, updated_game} = Games.next_round(updated_game.id)
      assert updated_game.current_round == 3
    end

    test "complete_round clears current word and drawer", %{room: room, players: [player1 | _]} do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, game} = Games.start_round(game.id, player1.id)

      # Verify word and drawer are set
      assert game.current_word != nil
      assert game.current_drawer_id == player1.id

      # Complete round
      {:ok, updated_game} = Games.complete_round(game.id)
      assert updated_game.current_word == nil
      assert updated_game.current_drawer_id == nil
    end

    test "end_game sets status to completed", %{room: room} do
      {:ok, game} = Games.create_game(room.id, 3)
      assert game.status == :in_progress

      {:ok, updated_game} = Games.end_current_game(game.id)
      assert updated_game.status == :completed
    end

    test "complete round flow: start -> complete -> next -> start", %{
      room: room,
      player_queue: player_queue
    } do
      {:ok, game} = Games.create_game(room.id, 3)

      # Round 1
      {:ok, game} = Games.start_round(game.id, Enum.at(player_queue, 0))
      assert game.current_round == 1
      assert game.current_word != nil
      assert game.current_drawer_id == Enum.at(player_queue, 0)

      # Complete round 1
      {:ok, game} = Games.complete_round(game.id)
      assert game.current_word == nil
      assert game.current_drawer_id == nil

      # Start round 2 with next drawer
      {:ok, game} = Games.next_round(game.id)
      {:ok, game} = Games.select_next_drawer(game.id, player_queue)
      {:ok, game} = Games.start_round(game.id, game.current_drawer_id)

      assert game.current_round == 2
      assert game.current_word != nil
      assert game.current_drawer_id in player_queue
    end
  end
end
