defmodule Scrawly.Games.ScoringTest do
  use ExUnit.Case, async: true

  alias Scrawly.Games.Scoring

  describe "guesser_points/3 - speed curve" do
    test "maximum points (excluding order bonus) at start of round" do
      # No order opt → default order 3 → 0 order bonus
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

    test "points scale with time remaining" do
      p1 = Scoring.guesser_points(45, 60)
      p2 = Scoring.guesser_points(15, 60)
      assert p1 > p2
      assert p1 == 50 + round(450 * 45 / 60)
      assert p2 == 50 + round(450 * 15 / 60)
    end

    test "works with different round durations" do
      assert Scoring.guesser_points(120, 120) == 500
      assert Scoring.guesser_points(60, 120) == 275
      assert Scoring.guesser_points(30, 30) == 500
    end

    test "never goes below base points" do
      assert Scoring.guesser_points(0, 60) == 50
      assert Scoring.guesser_points(-1, 60) >= 50
    end
  end

  describe "guesser_points/3 - order bonus" do
    test "first guesser receives +50 order bonus" do
      points = Scoring.guesser_points(30, 60, order: 1)
      assert points == 275 + 50
    end

    test "second guesser receives +25 order bonus" do
      points = Scoring.guesser_points(30, 60, order: 2)
      assert points == 275 + 25
    end

    test "third and later guessers receive no order bonus" do
      assert Scoring.guesser_points(30, 60, order: 3) == 275
      assert Scoring.guesser_points(30, 60, order: 7) == 275
    end

    test "default order yields no order bonus" do
      assert Scoring.guesser_points(30, 60) == Scoring.guesser_points(30, 60, order: 3)
    end

    test "order bonus stacks with speed bonus at full time" do
      assert Scoring.guesser_points(60, 60, order: 1) == 550
      assert Scoring.guesser_points(60, 60, order: 2) == 525
    end
  end

  describe "drawer_round_points/1" do
    test "empty list returns 0" do
      assert Scoring.drawer_round_points([]) == 0
    end

    test "single guess returns that guess's points" do
      assert Scoring.drawer_round_points([300]) == 300
    end

    test "returns floor mean of multiple guesses" do
      assert Scoring.drawer_round_points([100, 200, 300]) == 200
      assert Scoring.drawer_round_points([100, 150]) == 125
    end

    test "floors the mean (no rounding up)" do
      # mean of [100, 101] = 100.5 → floor = 100
      assert Scoring.drawer_round_points([100, 101]) == 100
    end
  end

  describe "constants" do
    test "base_points returns 50" do
      assert Scoring.base_points() == 50
    end

    test "max_points returns 550 (base + speed + first-order bonus)" do
      assert Scoring.max_points() == 550
    end

    test "order_bonus returns expected values" do
      assert Scoring.order_bonus(1) == 50
      assert Scoring.order_bonus(2) == 25
      assert Scoring.order_bonus(3) == 0
      assert Scoring.order_bonus(99) == 0
    end
  end

  describe "scoring integration scenarios" do
    test "first guesser early in round earns top score" do
      points = Scoring.guesser_points(55, 60, order: 1)
      assert points > 450
    end

    test "last-second third guesser earns near-minimum" do
      points = Scoring.guesser_points(3, 60, order: 5)
      assert points == 50 + round(450 * 3 / 60)
      assert points < 100
    end

    test "drawer mirrors strength of guessing field" do
      # Three quick guessers (order 1, 2, 3) at 50s of 60s round
      g1 = Scoring.guesser_points(50, 60, order: 1)
      g2 = Scoring.guesser_points(50, 60, order: 2)
      g3 = Scoring.guesser_points(50, 60, order: 3)

      drawer = Scoring.drawer_round_points([g1, g2, g3])
      assert drawer == div(g1 + g2 + g3, 3)
    end
  end
end
