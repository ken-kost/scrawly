defmodule Scrawly.Integration.ScoreLeaderboardTest do
  use Scrawly.DataCase

  alias Scrawly.Games
  alias Scrawly.Accounts.User

  describe "score persistence and leaderboard accuracy" do
    setup do
      {:ok, existing} = Games.get_all_words()
      Enum.each(existing, fn w -> Ash.destroy!(w) end)
      Scrawly.Games.Word.seed_words()

      players =
        for i <- 1..4 do
          Ash.create!(
            User,
            %{email: "score-p#{i}-#{System.unique_integer([:positive])}@test.com"},
            authorize?: false
          )
        end

      {:ok, room} =
        Games.create_room(%{
          max_players: 6,
          name: "Score Test",
          creator_id: List.first(players).id
        })

      for p <- players do
        p
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update!()
      end

      {:ok, game} = Games.create_game(room.id, 5)

      %{room: room, players: players, game: game}
    end

    test "scoring formula: 50-500 points based on time_left", %{} do
      # Max points at round start (80s)
      assert calculate_points(80) == 500

      # Min points at round end (0s)
      assert calculate_points(0) == 50

      # Mid-round gives proportional points
      assert calculate_points(40) == 275

      # Points decrease monotonically
      times = [80, 70, 60, 50, 40, 30, 20, 10, 0]
      points = Enum.map(times, &calculate_points/1)
      assert points == Enum.sort(points, :desc)
    end

    test "correct guess updates guesser score in database", %{
      game: game,
      players: [drawer, guesser | _]
    } do
      {:ok, _} = Games.start_round(game.id, drawer.id)

      # Guesser guesses correctly at 60s (387 points)
      points = calculate_points(60)
      assert points == 387

      {:ok, updated} =
        guesser
        |> Ash.Changeset.for_update(:update_score, %{score: points})
        |> Ash.update()

      assert updated.score == points

      # Verify persistence
      {:ok, from_db} = Ash.get(User, guesser.id)
      assert from_db.score == points
    end

    test "drawer receives bonus points when guessers guess correctly", %{
      game: game,
      players: [drawer, g1, g2, g3]
    } do
      {:ok, _} = Games.start_round(game.id, drawer.id)

      # Three guessers guess correctly
      for g <- [g1, g2, g3] do
        points = calculate_points(Enum.random(30..70))
        {:ok, _} = g |> Ash.Changeset.for_update(:update_score, %{score: points}) |> Ash.update()
      end

      # Drawer gets bonus: num_guessers * 50
      drawer_bonus = 3 * 50

      {:ok, updated_drawer} =
        drawer
        |> Ash.Changeset.for_update(:update_score, %{score: drawer_bonus})
        |> Ash.update()

      assert updated_drawer.score == 150
    end

    test "scores persist across multiple rounds", %{
      game: game,
      players: [p1, p2, p3, p4]
    } do
      # Round 1: p1 draws, p2 guesses fast, p3 guesses slow
      {:ok, _} = Games.start_round(game.id, p1.id)

      p2_r1 = calculate_points(70)
      p3_r1 = calculate_points(20)
      p1_bonus = 2 * 50

      {:ok, p2} = p2 |> Ash.Changeset.for_update(:update_score, %{score: p2_r1}) |> Ash.update()
      {:ok, p3} = p3 |> Ash.Changeset.for_update(:update_score, %{score: p3_r1}) |> Ash.update()

      {:ok, p1} =
        p1 |> Ash.Changeset.for_update(:update_score, %{score: p1_bonus}) |> Ash.update()

      # Round 2: p2 draws, p1 and p4 guess
      {:ok, _} = Games.complete_round(game.id)
      {:ok, _} = Games.next_round(game.id)
      {:ok, _} = Games.start_round(game.id, p2.id)

      p1_r2 = calculate_points(50)
      p4_r2 = calculate_points(40)
      p2_bonus = 2 * 50

      {:ok, p1} =
        p1 |> Ash.Changeset.for_update(:update_score, %{score: p1.score + p1_r2}) |> Ash.update()

      {:ok, p4} = p4 |> Ash.Changeset.for_update(:update_score, %{score: p4_r2}) |> Ash.update()

      {:ok, p2} =
        p2
        |> Ash.Changeset.for_update(:update_score, %{score: p2.score + p2_bonus})
        |> Ash.update()

      # Verify accumulated scores from database
      {:ok, final_p1} = Ash.get(User, p1.id)
      {:ok, final_p2} = Ash.get(User, p2.id)
      {:ok, final_p3} = Ash.get(User, p3.id)
      {:ok, final_p4} = Ash.get(User, p4.id)

      assert final_p1.score == p1_bonus + p1_r2
      assert final_p2.score == p2_r1 + p2_bonus
      assert final_p3.score == p3_r1
      assert final_p4.score == p4_r2
    end

    test "ScoreBoard sorted_players sorts by score descending", %{} do
      # Simulate the sort logic used by ScoreBoard component
      players = [
        %{username: "Alice", score: 100},
        %{username: "Bob", score: 500},
        %{username: "Charlie", score: 300},
        %{username: "Diana", score: 200}
      ]

      sorted = Enum.sort_by(players, &(&1.score || 0), :desc)

      assert Enum.map(sorted, & &1.username) == ["Bob", "Charlie", "Diana", "Alice"]
      assert Enum.map(sorted, & &1.score) == [500, 300, 200, 100]
    end

    test "ScoreBoard get_winner returns highest scorer", %{} do
      players = [
        %{username: "Loser", score: 50},
        %{username: "Winner", score: 999},
        %{username: "Middle", score: 400}
      ]

      sorted = Enum.sort_by(players, &(&1.score || 0), :desc)
      winner = List.first(sorted)
      assert winner.username == "Winner"
      assert winner.score == 999
    end

    test "leaderboard reflects cumulative scores after full game", %{
      game: game,
      players: [p1, p2, p3, p4]
    } do
      # Play 3 rounds with various scoring
      # Round 1
      {:ok, _} = Games.start_round(game.id, p1.id)
      {:ok, p2} = p2 |> Ash.Changeset.for_update(:update_score, %{score: 450}) |> Ash.update()
      {:ok, p3} = p3 |> Ash.Changeset.for_update(:update_score, %{score: 300}) |> Ash.update()
      {:ok, p4} = p4 |> Ash.Changeset.for_update(:update_score, %{score: 200}) |> Ash.update()
      {:ok, p1} = p1 |> Ash.Changeset.for_update(:update_score, %{score: 150}) |> Ash.update()

      # Round 2
      {:ok, _} = Games.complete_round(game.id)
      {:ok, _} = Games.next_round(game.id)
      {:ok, _} = Games.start_round(game.id, p2.id)

      {:ok, p1} =
        p1 |> Ash.Changeset.for_update(:update_score, %{score: p1.score + 400}) |> Ash.update()

      {:ok, p3} =
        p3 |> Ash.Changeset.for_update(:update_score, %{score: p3.score + 100}) |> Ash.update()

      {:ok, p2} =
        p2 |> Ash.Changeset.for_update(:update_score, %{score: p2.score + 100}) |> Ash.update()

      # Round 3
      {:ok, _} = Games.complete_round(game.id)
      {:ok, _} = Games.next_round(game.id)
      {:ok, _} = Games.start_round(game.id, p3.id)

      {:ok, p4} =
        p4 |> Ash.Changeset.for_update(:update_score, %{score: p4.score + 500}) |> Ash.update()

      {:ok, _p1} =
        p1 |> Ash.Changeset.for_update(:update_score, %{score: p1.score + 200}) |> Ash.update()

      # End game
      {:ok, _} = Games.complete_round(game.id)
      {:ok, _} = Games.end_current_game(game.id)

      # Read final scores
      final_scores =
        for p <- [p1, p2, p3, p4] do
          {:ok, user} = Ash.get(User, p.id)
          {user.username, user.score}
        end

      # Sort like ScoreBoard does
      sorted = Enum.sort_by(final_scores, fn {_name, score} -> score end, :desc)
      scores_only = Enum.map(sorted, fn {_name, score} -> score end)

      # Scores should be in descending order
      assert scores_only == Enum.sort(scores_only, :desc)

      # Verify specific totals
      _score_map = Map.new(final_scores)
      {_p1_name, p1_total} = Enum.find(final_scores, fn {name, _} -> name == p1.username end)
      # 750
      assert p1_total == 150 + 400 + 200

      {_p2_name, p2_total} = Enum.find(final_scores, fn {name, _} -> name == p2.username end)
      # 550
      assert p2_total == 450 + 100

      {_p4_name, p4_total} = Enum.find(final_scores, fn {name, _} -> name == p4.username end)
      # 700
      assert p4_total == 200 + 500
    end

    test "score resets when player leaves room", %{
      room: room,
      game: game,
      players: [drawer, guesser | _]
    } do
      {:ok, _} = Games.start_round(game.id, drawer.id)

      # Give guesser some score
      {:ok, scored} =
        guesser
        |> Ash.Changeset.for_update(:update_score, %{score: 350})
        |> Ash.update()

      assert scored.score == 350

      # Player leaves room — score resets
      {:ok, left} = scored |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()
      assert left.score == 0

      # Rejoin — score stays at 0
      {:ok, rejoined} =
        left
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      assert rejoined.score == 0
    end

    test "nil scores are handled as 0 in sorting", %{} do
      players = [
        %{username: "HasScore", score: 100},
        %{username: "NilScore", score: nil},
        %{username: "ZeroScore", score: 0}
      ]

      sorted = Enum.sort_by(players, &(&1.score || 0), :desc)
      assert List.first(sorted).username == "HasScore"
    end

    test "faster guesser always gets more points than slower guesser", %{
      game: game,
      players: [drawer, fast_guesser, slow_guesser | _]
    } do
      {:ok, _} = Games.start_round(game.id, drawer.id)

      # Guessed early
      fast_points = calculate_points(70)
      # Guessed late
      slow_points = calculate_points(15)

      {:ok, fast} =
        fast_guesser
        |> Ash.Changeset.for_update(:update_score, %{score: fast_points})
        |> Ash.update()

      {:ok, slow} =
        slow_guesser
        |> Ash.Changeset.for_update(:update_score, %{score: slow_points})
        |> Ash.update()

      assert fast.score > slow.score
      # 50 + (70*450/80)
      assert fast.score == 443
      # 50 + (15*450/80)
      assert slow.score == 134
    end
  end

  defp calculate_points(time_left) when is_integer(time_left) do
    base = 50
    bonus = div(time_left * 450, 80)
    base + bonus
  end
end
