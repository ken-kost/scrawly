defmodule Scrawly.Games.Scoring do
  @moduledoc """
  Scoring calculations for Scrawly game rounds — modeled on skribbl.io conventions.

  ## Guesser Points

      (base(50) + speed_bonus + order_bonus) × difficulty multiplier, rounded

  - `speed_bonus = round(time_left / round_duration * 450)` → 0..450
  - `order_bonus`: 1st correct guesser **+50**, 2nd **+25**, others **+0**
  - the multiplier comes from the word's difficulty (`multiplier/1`): easy
    ×1, medium ×1.25, hard ×1.5. An AI word has no difficulty: ×1.

  Range: 50..550 on an easy word, up to 825 on a hard one. No hint penalty —
  letter reveals do not reduce points.

  ## Drawer Points

  Drawer earns **floor(mean of guesser_points this round)**, so the
  multiplier carries over to them. If nobody guesses, drawer scores **0**
  (no timeout penalty).
  """

  @base_points 50
  @max_speed_bonus 450
  @order_bonuses %{1 => 50, 2 => 25}
  @multipliers %{easy: 1, medium: 1.25, hard: 1.5}

  @doc """
  Calculate points for a correct guess.

  ## Parameters

  - `time_left` - seconds remaining when guess was made
  - `round_duration` - total round duration in seconds
  - `opts` - keyword list:
    - `:order` - 1-based guess order in this round. Default: 3 (no order bonus).
    - `:multiplier` - the word's difficulty multiplier (`multiplier/1`).
      Default: 1. The result is rounded to a whole number.
  """
  def guesser_points(time_left, round_duration, opts \\ []) do
    order = Keyword.get(opts, :order, 3)
    multiplier = Keyword.get(opts, :multiplier, 1)

    speed_bonus = round(@max_speed_bonus * time_left / max(round_duration, 1))
    order_bonus = Map.get(@order_bonuses, order, 0)

    round((@base_points + max(speed_bonus, 0) + order_bonus) * multiplier)
  end

  @doc """
  The points multiplier of a word's difficulty: 1 for `:easy`, 1.25 for
  `:medium`, 1.5 for `:hard`, and 1 for anything else (an AI word has no
  difficulty).

      iex> Scrawly.Games.Scoring.multiplier(:hard)
      1.5
      iex> Scrawly.Games.Scoring.multiplier(nil)
      1
  """
  def multiplier(difficulty), do: Map.get(@multipliers, difficulty, 1)

  @doc """
  The multiplier's bonus as a whole percentage, as the game shows it:

      iex> Scrawly.Games.Scoring.bonus_percent(:medium)
      25
      iex> Scrawly.Games.Scoring.bonus_percent(:easy)
      0
  """
  def bonus_percent(difficulty), do: round((multiplier(difficulty) - 1) * 100)

  @doc """
  Drawer points for a round: floor(mean(guesser_points)). Returns 0 for an empty list.
  """
  def drawer_round_points([]), do: 0

  def drawer_round_points(guesser_points_list) when is_list(guesser_points_list) do
    sum = Enum.sum(guesser_points_list)
    div(sum, length(guesser_points_list))
  end

  @doc "Returns the base points constant (minimum guesser points)."
  def base_points, do: @base_points

  @doc """
  Returns the maximum guesser points without a difficulty bonus (base + max
  speed bonus + 1st-order bonus).
  """
  def max_points, do: @base_points + @max_speed_bonus + Map.get(@order_bonuses, 1, 0)

  @doc "Returns the order bonus for a given 1-based guess order."
  def order_bonus(order), do: Map.get(@order_bonuses, order, 0)
end
