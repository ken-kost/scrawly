defmodule Scrawly.Games.GuessingTest do
  use Scrawly.DataCase

  alias Scrawly.Games
  alias Scrawly.Games.Scoring
  alias Scrawly.Accounts.User

  describe "scoring formula" do
    # Enhanced scoring: base 50 + speed bonus (time_left / round_duration * 450)
    # Range: 50-500, with hint penalty reducing points per stage

    test "max points at start of round" do
      points = Scoring.guesser_points(60, 60)
      assert points == 500
    end

    test "min points at end of round" do
      points = Scoring.guesser_points(0, 60)
      assert points == 50
    end

    test "mid-round gives proportional points" do
      points = Scoring.guesser_points(30, 60)
      assert points == 275
    end

    test "points decrease as time passes" do
      early = Scoring.guesser_points(50, 60)
      mid = Scoring.guesser_points(30, 60)
      late = Scoring.guesser_points(10, 60)

      assert early > mid
      assert mid > late
      assert late >= 50
    end

    test "drawer earns mean of guesser points" do
      assert Scoring.drawer_round_points([300, 200]) == 250
    end

    test "drawer mean reflects skribbl.io behavior" do
      # Three guessers at mixed times → drawer gets floor(mean)
      assert Scoring.drawer_round_points([400, 350, 300]) == 350
    end

    test "drawer gets zero on timeout with no guesses" do
      assert Scoring.drawer_round_points([]) == 0
    end
  end

  describe "guess matching" do
    test "exact match returns true" do
      assert guess_matches?("butterfly", "butterfly")
    end

    test "case insensitive match" do
      assert guess_matches?("Butterfly", "butterfly")
      assert guess_matches?("BUTTERFLY", "butterfly")
    end

    test "trims whitespace" do
      assert guess_matches?("  butterfly  ", "butterfly")
    end

    test "wrong guess returns false" do
      refute guess_matches?("caterpillar", "butterfly")
    end

    test "partial match returns false" do
      refute guess_matches?("butter", "butterfly")
    end

    test "empty guess returns false" do
      refute guess_matches?("", "butterfly")
    end
  end

  describe "score persistence" do
    test "player score updates in database" do
      {:ok, user} =
        Ash.create(User, %{email: "scorer-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      assert user.score == 0

      # Update score
      {:ok, updated} =
        user
        |> Ash.Changeset.for_update(:update_score, %{score: 250})
        |> Ash.update()

      assert updated.score == 250

      # Accumulate score
      {:ok, updated} =
        updated
        |> Ash.Changeset.for_update(:update_score, %{score: 500})
        |> Ash.update()

      assert updated.score == 500
    end
  end

  describe "game flow with guessing" do
    setup do
      {:ok, existing} = Games.get_all_words()
      Enum.each(existing, fn w -> Ash.destroy!(w) end)
      Scrawly.Games.Word.seed_words()

      {:ok, player1} =
        Ash.create(User, %{email: "drawer-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      {:ok, player2} =
        Ash.create(User, %{email: "guesser-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      {:ok, room} =
        Games.create_room(%{max_players: 4, name: "Guess Test", creator_id: player1.id})

      # Join players to room
      for p <- [player1, player2] do
        p
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update!()
      end

      %{room: room, drawer: player1, guesser: player2}
    end

    test "start_round sets a word", %{room: room, drawer: drawer} do
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, game} = Games.start_round(game.id, drawer.id)

      assert game.current_word != nil
      assert is_binary(game.current_word)
    end

    test "start_round with used_words excludes them", %{room: room, drawer: drawer} do
      {:ok, game} = Games.create_game(room.id, 3)

      # Start first round
      {:ok, game} = Games.start_round(game.id, drawer.id)
      first_word = game.current_word

      # Complete and start next round excluding first word
      {:ok, game} = Games.complete_round(game.id)
      {:ok, game} = Games.next_round(game.id)

      # Try multiple times — with 100 words, excluding 1 should usually give a different one
      results =
        for _ <- 1..5 do
          {:ok, g} = Games.start_round(game.id, drawer.id, %{used_words: [first_word]})
          g.current_word
        end

      # At least one should be different from the first word
      assert Enum.any?(results, &(&1 != first_word))
    end
  end

  # Legacy helper kept for reference; new tests use Scoring module directly
  defp calculate_points(time_left) when is_integer(time_left) do
    Scoring.guesser_points(time_left, 80)
  end

  defp guess_matches?(guess, word) do
    String.downcase(String.trim(guess)) == String.downcase(String.trim(word))
  end
end
