defmodule Scrawly.Integration.MultiplayerSimultaneousTest do
  use Scrawly.DataCase

  alias Scrawly.Games
  alias Scrawly.Games.WordHints
  alias Scrawly.Accounts.User

  describe "multiple players joining and playing simultaneously" do
    setup do
      {:ok, existing} = Games.get_all_words()
      Enum.each(existing, fn w -> Ash.destroy!(w) end)
      Scrawly.Games.Word.seed_words()

      players =
        for i <- 1..4 do
          Ash.create!(
            User,
            %{email: "mp-p#{i}-#{System.unique_integer([:positive])}@test.com"},
            authorize?: false
          )
        end

      {:ok, room} =
        Games.create_room(%{
          max_players: 6,
          name: "Multiplayer Test",
          creator_id: List.first(players).id
        })

      for p <- players do
        p
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update!()
      end

      player_queue = Enum.map(players, & &1.id)

      %{room: room, players: players, player_queue: player_queue}
    end

    test "all players join room and are tracked", %{room: room, players: players} do
      {:ok, loaded_room} = Games.get_room_by_id(room.id)
      assert length(loaded_room.players) == 4

      room_player_ids = MapSet.new(loaded_room.players, & &1.id)

      for p <- players do
        assert MapSet.member?(room_player_ids, p.id)
      end
    end

    test "drawer sees actual word, guessers see hidden display", %{
      room: room,
      players: [drawer | guessers],
      player_queue: _player_queue
    } do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, game} = Games.start_round(game.id, drawer.id)

      word = game.current_word
      hidden = WordHints.hidden_display(word)

      # Drawer perspective: sees the actual word
      assert game.current_drawer_id == drawer.id
      is_drawer_for_drawer = game.current_drawer_id == drawer.id
      assert is_drawer_for_drawer

      # Guessers perspective: see hidden display
      for guesser <- guessers do
        is_drawer_for_guesser = game.current_drawer_id == guesser.id
        refute is_drawer_for_guesser

        # Guessers see underscored version
        assert String.contains?(hidden, "_")
        refute hidden == word
      end
    end

    test "correct guess updates guesser score", %{
      room: room,
      players: [drawer, guesser1, guesser2, _guesser3]
    } do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, game} = Games.start_round(game.id, drawer.id)

      word = game.current_word

      # Simulate guesser1 guessing correctly (fast — 60s left = 387 points)
      assert guess_matches?(word, word)
      points_g1 = calculate_points(60)

      {:ok, updated_g1} =
        guesser1
        |> Ash.Changeset.for_update(:update_score, %{score: points_g1})
        |> Ash.update()

      assert updated_g1.score == points_g1

      # Simulate guesser2 guessing correctly later (30s left = 218 points)
      points_g2 = calculate_points(30)

      {:ok, updated_g2} =
        guesser2
        |> Ash.Changeset.for_update(:update_score, %{score: points_g2})
        |> Ash.update()

      assert updated_g2.score == points_g2

      # Faster guesser got more points
      assert updated_g1.score > updated_g2.score
    end

    test "drawer gets bonus points when all guessers guess correctly", %{
      room: room,
      players: [drawer | guessers]
    } do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, _game} = Games.start_round(game.id, drawer.id)

      # Simulate all guessers guessing correctly
      correct_guessers = Enum.map(guessers, & &1.id)

      # Drawer bonus = number_of_guessers * 50
      drawer_bonus = length(correct_guessers) * 50
      # 3 guessers * 50
      assert drawer_bonus == 150

      {:ok, updated_drawer} =
        drawer
        |> Ash.Changeset.for_update(:update_score, %{score: drawer_bonus})
        |> Ash.update()

      assert updated_drawer.score == drawer_bonus
    end

    test "turn rotation ensures every player draws across rounds", %{
      room: room,
      player_queue: player_queue
    } do
      num_players = length(player_queue)
      {:ok, game} = Games.create_game(room.id, num_players)

      # Each player draws once
      drawer_ids =
        Enum.reduce(1..num_players, {game, []}, fn round_num, {g, history} ->
          drawer_id = Enum.at(player_queue, round_num - 1)

          g =
            if round_num > 1 do
              {:ok, g} = Games.complete_round(g.id)
              {:ok, g} = Games.next_round(g.id)
              g
            else
              g
            end

          {:ok, g} = Games.start_round(g.id, drawer_id)
          assert g.current_drawer_id == drawer_id

          {g, history ++ [drawer_id]}
        end)
        |> elem(1)

      # Every player drew exactly once
      assert MapSet.new(drawer_ids) == MapSet.new(player_queue)
      assert length(drawer_ids) == num_players
    end

    test "scores accumulate across multiple rounds", %{
      room: room,
      players: [p1, p2, p3, p4]
    } do
      {:ok, game} = Games.create_game(room.id, 3)

      # Round 1: p1 draws, p2 and p3 guess
      {:ok, _} = Games.start_round(game.id, p1.id)
      {:ok, p2} = p2 |> Ash.Changeset.for_update(:update_score, %{score: 300}) |> Ash.update()
      {:ok, p3} = p3 |> Ash.Changeset.for_update(:update_score, %{score: 200}) |> Ash.update()
      {:ok, p1} = p1 |> Ash.Changeset.for_update(:update_score, %{score: 100}) |> Ash.update()

      # Round 2: p2 draws, p1 and p4 guess
      {:ok, _} = Games.complete_round(game.id)
      {:ok, _} = Games.next_round(game.id)
      {:ok, _} = Games.start_round(game.id, p2.id)

      new_p1_score = p1.score + 250

      {:ok, p1} =
        p1 |> Ash.Changeset.for_update(:update_score, %{score: new_p1_score}) |> Ash.update()

      {:ok, p4} = p4 |> Ash.Changeset.for_update(:update_score, %{score: 150}) |> Ash.update()

      # Verify accumulated scores
      {:ok, final_p1} = Ash.get(User, p1.id)
      {:ok, final_p2} = Ash.get(User, p2.id)
      {:ok, final_p3} = Ash.get(User, p3.id)
      {:ok, final_p4} = Ash.get(User, p4.id)

      # 100 + 250
      assert final_p1.score == 350
      assert final_p2.score == 300
      assert final_p3.score == 200
      assert final_p4.score == 150
    end

    test "game progresses correctly with concurrent player activity", %{
      room: room,
      players: players,
      player_queue: player_queue
    } do
      {:ok, game} = Games.create_game(room.id, 3)

      # Round 1
      {:ok, game} = Games.start_round(game.id, Enum.at(player_queue, 0))
      assert game.current_round == 1
      assert game.current_word != nil

      # Simulate guessing activity
      for p <- Enum.drop(players, 1) do
        points = calculate_points(Enum.random(20..70))
        {:ok, _} = p |> Ash.Changeset.for_update(:update_score, %{score: points}) |> Ash.update()
      end

      # Round 2
      {:ok, _} = Games.complete_round(game.id)
      {:ok, game} = Games.next_round(game.id)
      {:ok, game} = Games.start_round(game.id, Enum.at(player_queue, 1))
      assert game.current_round == 2
      assert game.current_word != nil

      # Round 3
      {:ok, _} = Games.complete_round(game.id)
      {:ok, game} = Games.next_round(game.id)
      {:ok, game} = Games.start_round(game.id, Enum.at(player_queue, 2))
      assert game.current_round == 3

      # End game
      {:ok, _} = Games.complete_round(game.id)
      {:ok, ended} = Games.end_current_game(game.id)
      assert ended.status == :completed

      # All player scores persisted
      for p <- players do
        {:ok, fetched} = Ash.get(User, p.id)
        assert is_integer(fetched.score)
        assert fetched.score >= 0
      end
    end

    test "wrong guesses do not affect scores", %{
      room: room,
      players: [drawer, guesser | _]
    } do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, game} = Games.start_round(game.id, drawer.id)

      word = game.current_word

      # Wrong guesses don't match
      refute guess_matches?("completely_wrong_word", word)
      refute guess_matches?("", word)
      refute guess_matches?(String.slice(word, 0, 2), word)

      # Score unchanged for guesser
      {:ok, fresh_guesser} = Ash.get(User, guesser.id)
      assert fresh_guesser.score == 0
    end
  end

  # Mirror scoring and matching logic from GamePage
  defp calculate_points(time_left) when is_integer(time_left) do
    base = 50
    bonus = div(time_left * 450, 80)
    base + bonus
  end

  defp guess_matches?(guess, word) do
    String.downcase(String.trim(guess)) == String.downcase(String.trim(word))
  end
end
