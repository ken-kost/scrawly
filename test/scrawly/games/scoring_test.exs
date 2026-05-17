defmodule Scrawly.Games.ScoringTest do
  use ExUnit.Case, async: true

  alias Scrawly.Games.Scoring

  describe "guesser_points/3 - speed curve" do
    test "maximum points at start of round (full time left)" do
      points = Scoring.guesser_points(60, 60)
      assert points == 500
    end

    test "minimum points at end of round (no time left)" do
      points = Scoring.guesser_points(0, 60)
      assert points == 50
    end

    test "mid-round gives mid-range points" do
      points = Scoring.guesser_points(30, 60)
      assert points == 275
    end

    test "points scale linearly with time remaining" do
      p1 = Scoring.guesser_points(45, 60)
      p2 = Scoring.guesser_points(15, 60)
      # p1 should be proportionally higher
      assert p1 > p2
      assert p1 == 50 + round(450 * 45 / 60)
      assert p2 == 50 + round(450 * 15 / 60)
    end

    test "works with different round durations" do
      # 120s round, full time
      assert Scoring.guesser_points(120, 120) == 500
      # 120s round, half time
      assert Scoring.guesser_points(60, 120) == 275
      # 30s round, full time
      assert Scoring.guesser_points(30, 30) == 500
    end

    test "never goes below base points" do
      assert Scoring.guesser_points(0, 60) == 50
      # edge case
      assert Scoring.guesser_points(-1, 60) >= 50
    end
  end

  describe "guesser_points/3 - hint penalty" do
    test "no penalty at hint stage 0" do
      points = Scoring.guesser_points(30, 60, hint_stage: 0)
      assert points == 275
    end

    test "10% reduction at hint stage 1" do
      base = Scoring.guesser_points(30, 60)
      with_hint = Scoring.guesser_points(30, 60, hint_stage: 1)
      assert with_hint == round(base * 0.90)
    end

    test "20% reduction at hint stage 2" do
      base = Scoring.guesser_points(30, 60)
      with_hint = Scoring.guesser_points(30, 60, hint_stage: 2)
      assert with_hint == round(base * 0.80)
    end

    test "30% reduction at hint stage 3" do
      base = Scoring.guesser_points(30, 60)
      with_hint = Scoring.guesser_points(30, 60, hint_stage: 3)
      assert with_hint == round(base * 0.70)
    end

    test "40% reduction at hint stage 4" do
      base = Scoring.guesser_points(30, 60)
      with_hint = Scoring.guesser_points(30, 60, hint_stage: 4)
      assert with_hint == round(base * 0.60)
    end

    test "hint penalty never reduces below base points" do
      # Even with max hint penalty at 0 time left, floor is 50
      points = Scoring.guesser_points(0, 60, hint_stage: 4)
      assert points == 50
    end

    test "hint penalty applies proportionally" do
      # At full time with stage 4: 500 * 0.60 = 300
      points = Scoring.guesser_points(60, 60, hint_stage: 4)
      assert points == 300
    end
  end

  describe "drawer_points/3" do
    test "no penalty when time hasn't expired and no guesses" do
      assert Scoring.drawer_points(0, 3) == 0
    end

    test "penalty when time expires and no guesses" do
      assert Scoring.drawer_points(0, 3, time_up: true) == -25
    end

    test "+50 per correct guesser" do
      assert Scoring.drawer_points(1, 3) == 50
      assert Scoring.drawer_points(2, 3) == 100
      assert Scoring.drawer_points(3, 4) == 150
    end

    test "+100 bonus when all guessers guess correctly" do
      # 3 guessers, all correct: 3*50 + 100 = 250
      assert Scoring.drawer_points(3, 3) == 250
    end

    test "all-guessed bonus requires total_guessers > 0" do
      # Edge case: no guessers at all
      assert Scoring.drawer_points(0, 0) == 0
    end

    test "partial guesses on timeout still earn per-guesser points" do
      # 2 of 4 guessed, time ran out
      assert Scoring.drawer_points(2, 4, time_up: true) == 100
    end

    test "all guessed even with time_up flag gives bonus" do
      # Shouldn't normally happen (timer stops when all guess), but test edge case
      assert Scoring.drawer_points(3, 3, time_up: true) == 250
    end
  end

  describe "guesser_points_with_hints/3" do
    test "integrates with WordHints to determine hint stage" do
      # At 40s left in 60s round, hint stage is 1 (25-50% elapsed)
      points = Scoring.guesser_points_with_hints(40, 60, "butterfly")
      expected = Scoring.guesser_points(40, 60, hint_stage: 1)
      assert points == expected
    end

    test "no hint penalty when no hints revealed" do
      # At 50s left in 60s round, hint stage is 0
      points = Scoring.guesser_points_with_hints(50, 60, "butterfly")
      expected = Scoring.guesser_points(50, 60, hint_stage: 0)
      assert points == expected
    end

    test "max hint penalty at end of round" do
      # At 5s left in 60s round, hint stage is 4
      points = Scoring.guesser_points_with_hints(5, 60, "butterfly")
      expected = Scoring.guesser_points(5, 60, hint_stage: 4)
      assert points == expected
    end
  end

  describe "constants" do
    test "base_points returns 50" do
      assert Scoring.base_points() == 50
    end

    test "max_points returns 500" do
      assert Scoring.max_points() == 500
    end

    test "drawer_per_guesser returns 50" do
      assert Scoring.drawer_per_guesser() == 50
    end

    test "drawer_timeout_penalty returns -25" do
      assert Scoring.drawer_timeout_penalty() == -25
    end
  end

  describe "scoring integration scenarios" do
    test "early guess with no hints yields maximum points" do
      # Guess at 55s of 60s round = stage 0, high speed bonus
      points = Scoring.guesser_points_with_hints(55, 60, "cat")
      assert points > 400
    end

    test "late guess with many hints yields minimum viable points" do
      # Guess at 3s of 60s round = stage 4, low speed bonus
      points = Scoring.guesser_points_with_hints(3, 60, "butterfly")
      assert points >= 50
      assert points < 100
    end

    test "drawer scores proportionally to how many players guess" do
      # 1 of 5 guessed
      assert Scoring.drawer_points(1, 5) == 50
      # 3 of 5 guessed
      assert Scoring.drawer_points(3, 5) == 150
      # 5 of 5 guessed (all + bonus)
      assert Scoring.drawer_points(5, 5) == 350
    end

    test "total round score for perfect round (all guess quickly)" do
      # 3 guessers all guess at ~50s left
      guesser_pts = Scoring.guesser_points(50, 60, hint_stage: 0)
      drawer_pts = Scoring.drawer_points(3, 3)

      total = guesser_pts * 3 + drawer_pts
      assert total > 1000
    end
  end
end
