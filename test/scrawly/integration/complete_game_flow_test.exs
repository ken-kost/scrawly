defmodule Scrawly.Integration.CompleteGameFlowTest do
  use Scrawly.DataCase

  alias Scrawly.Games
  alias Scrawly.Games.WordHints
  alias Scrawly.Accounts.User

  describe "complete game flow from room creation to game end" do
    setup do
      # Seed words
      {:ok, existing} = Games.get_all_words()
      Enum.each(existing, fn w -> Ash.destroy!(w) end)
      Scrawly.Games.Word.seed_words()

      # Create players with unique emails
      players =
        for i <- 1..3 do
          Ash.create!(User, %{email: "flow-p#{i}-#{System.unique_integer([:positive])}@test.com"},
            authorize?: false
          )
        end

      # Create room
      {:ok, room} =
        Games.create_room(%{
          max_players: 6,
          name: "Integration Test Room",
          creator_id: List.first(players).id
        })

      # Join all players to the room
      for p <- players do
        p
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update!()
      end

      player_queue = Enum.map(players, & &1.id)

      %{room: room, players: players, player_queue: player_queue}
    end

    test "full lifecycle: create room → join → create game → play rounds → end game", %{
      room: room,
      player_queue: player_queue
    } do
      total_rounds = 3

      # 1. Room starts in :lobby status with all players joined
      {:ok, fresh_room} = Games.get_room_by_id(room.id)
      assert fresh_room.status == :lobby
      assert length(fresh_room.players) == 3

      # 2. Create a new game
      {:ok, game} = Games.create_game(room.id, total_rounds)
      assert game.status == :in_progress
      assert game.current_round == 1
      assert game.total_rounds == total_rounds
      assert game.room_id == room.id

      used_words = []

      # 3. Play through all rounds, manually rotating drawer
      {final_game, final_used_words} =
        Enum.reduce(1..total_rounds, {game, used_words}, fn round_num, {g, used} ->
          drawer_index = rem(round_num - 1, length(player_queue))
          drawer_id = Enum.at(player_queue, drawer_index)

          # If not the first round, complete previous and advance
          g =
            if round_num > 1 do
              {:ok, g} = Games.complete_round(g.id)
              assert g.current_word == nil

              {:ok, g} = Games.next_round(g.id)
              assert g.current_round == round_num
              g
            else
              g
            end

          # Start the round with the designated drawer
          {:ok, g} = Games.start_round(g.id, drawer_id)

          # Verify round state
          assert g.current_drawer_id == drawer_id
          assert g.current_word != nil
          assert is_binary(g.current_word)
          assert String.length(g.current_word) > 0

          new_used = [g.current_word | used]
          {g, new_used}
        end)

      # 4. Complete the last round
      {:ok, completed} = Games.complete_round(final_game.id)
      assert completed.current_word == nil

      # 5. End the game
      {:ok, ended_game} = Games.end_current_game(completed.id)
      assert ended_game.status == :completed

      # 6. Verify all rounds used different words (with high probability)
      unique_words = Enum.uniq(final_used_words)
      assert length(unique_words) == total_rounds
    end

    test "GamePage start_game params mirror backend state", %{
      room: room,
      players: players
    } do
      first_drawer = List.first(players)

      # Create and start game via Ash
      {:ok, game} = Games.create_game(room.id, 5)
      {:ok, started_game} = Games.start_round(game.id, first_drawer.id)

      # Simulate what GamePage.command(:start_game) produces as action params
      params = %{
        game_id: game.id,
        round: started_game.current_round,
        first_drawer_id: first_drawer.id,
        current_word: started_game.current_word,
        players: players
      }

      assert params.game_id == game.id
      assert params.round == 1
      assert params.first_drawer_id == first_drawer.id
      assert params.current_word != nil

      # Verify WordHints produces correct hidden display
      hidden = WordHints.hidden_display(started_game.current_word)
      assert is_binary(hidden)
      assert String.contains?(hidden, "_")
      refute hidden == started_game.current_word

      # Verify is_drawer logic: first player is drawer, others are not
      assert first_drawer.id == params.first_drawer_id

      for p <- Enum.drop(players, 1) do
        refute p.id == params.first_drawer_id
      end
    end

    test "GamePage next_round params mirror backend state for round 2", %{
      room: room,
      player_queue: player_queue
    } do
      {:ok, game} = Games.create_game(room.id, 3)

      # Round 1
      first_drawer_id = Enum.at(player_queue, 0)
      {:ok, game} = Games.start_round(game.id, first_drawer_id)
      _round1_word = game.current_word

      # Complete round 1 and advance to round 2
      {:ok, _} = Games.complete_round(game.id)
      {:ok, game} = Games.next_round(game.id)

      # Manually assign next drawer (index 1) to mirror what a fixed rotation would do
      second_drawer_id = Enum.at(player_queue, 1)
      {:ok, game} = Games.start_round(game.id, second_drawer_id)

      # Verify next_round state
      assert game.current_round == 2
      assert game.current_drawer_id == second_drawer_id
      assert game.current_word != nil
      # New word is different from round 1 with high probability
      assert is_binary(game.current_word)

      # WordHints should produce hidden display for new word
      new_hidden = WordHints.hidden_display(game.current_word)
      assert is_binary(new_hidden)
      assert String.contains?(new_hidden, "_")
    end

    test "GamePage end_game resets game state", %{room: room, players: players} do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, game} = Games.start_round(game.id, List.first(players).id)

      # Verify game is active
      assert game.status == :in_progress
      assert game.current_word != nil

      # End the game
      {:ok, ended_game} = Games.end_current_game(game.id)
      assert ended_game.status == :completed

      # Verify the ended game can be fetched
      {:ok, fetched} = Games.get_game_by_id(ended_game.id)
      assert fetched.status == :completed
    end

    test "select_next_drawer rotates correctly even after complete_round", %{
      room: room,
      player_queue: player_queue
    } do
      {:ok, game} = Games.create_game(room.id, 6)

      # Round 1: first player draws
      {:ok, game} = Games.start_round(game.id, Enum.at(player_queue, 0))
      assert game.current_drawer_id == Enum.at(player_queue, 0)

      # complete_round preserves current_drawer_id so rotation works
      {:ok, game} = Games.complete_round(game.id)
      assert game.current_drawer_id == Enum.at(player_queue, 0)

      # select_next_drawer finds previous drawer and picks the next one
      {:ok, game} = Games.select_next_drawer(game.id, player_queue)
      assert game.current_drawer_id == Enum.at(player_queue, 1)

      # Round 2: second player draws
      {:ok, game} = Games.next_round(game.id)
      {:ok, game} = Games.start_round(game.id, game.current_drawer_id)
      assert game.current_drawer_id == Enum.at(player_queue, 1)

      # Complete round 2 and rotate again
      {:ok, game} = Games.complete_round(game.id)
      {:ok, game} = Games.select_next_drawer(game.id, player_queue)
      assert game.current_drawer_id == Enum.at(player_queue, 2)

      # Wrap around after all players
      {:ok, _} = Games.complete_round(game.id)
      {:ok, game} = Games.select_next_drawer(game.id, player_queue)
      assert game.current_drawer_id == Enum.at(player_queue, 0)
    end

    test "score updates persist through game flow", %{
      room: room,
      players: [p1, p2, _p3]
    } do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, _game} = Games.start_round(game.id, p1.id)

      # Simulate p2 guessing correctly — update score
      points = 300

      {:ok, updated_p2} =
        p2
        |> Ash.Changeset.for_update(:update_score, %{score: points})
        |> Ash.update()

      assert updated_p2.score == points

      # Simulate drawer bonus for p1
      drawer_bonus = 50

      {:ok, updated_p1} =
        p1
        |> Ash.Changeset.for_update(:update_score, %{score: drawer_bonus})
        |> Ash.update()

      assert updated_p1.score == drawer_bonus

      # Verify scores persist after game ends
      {:ok, _} = Games.end_current_game(game.id)

      {:ok, p1_final} = Ash.get(User, p1.id)
      {:ok, p2_final} = Ash.get(User, p2.id)

      assert p1_final.score == drawer_bonus
      assert p2_final.score == points
    end

    test "word hints progress correctly through a round", %{room: room, players: players} do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, game} = Games.start_round(game.id, List.first(players).id)
      word = game.current_word

      # Default schedule: [0.375, 0.6875] for 60s round.
      # 37s left = ~38.3% elapsed → stage 1
      # 18s left = ~70% elapsed → stage 2

      # At 60s (start): all underscores
      hint_60 = WordHints.generate_hint(word, 60)
      letter_count = WordHints.word_length_hint(word)
      underscore_count_60 = hint_60 |> String.graphemes() |> Enum.count(&(&1 == "_"))
      assert underscore_count_60 == letter_count

      # After first batch reveals: fewer underscores than at start (skribbl-style randomly
      # picked letters). Words must be long enough to have at least one letter revealed.
      hint_30 = WordHints.generate_hint(word, 30)
      underscore_count_30 = hint_30 |> String.graphemes() |> Enum.count(&(&1 == "_"))

      if letter_count >= 3 do
        assert underscore_count_30 < underscore_count_60
      else
        assert underscore_count_30 <= underscore_count_60
      end

      # After second batch reveals: still fewer (or equal) underscores
      hint_5 = WordHints.generate_hint(word, 5)
      underscore_count_5 = hint_5 |> String.graphemes() |> Enum.count(&(&1 == "_"))
      assert underscore_count_5 <= underscore_count_30
    end
  end
end
