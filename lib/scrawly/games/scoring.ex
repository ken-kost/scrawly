defmodule Scrawly.Games.Scoring do
  @moduledoc """
  Scoring calculations for Scrawly game rounds — modeled on skribbl.io conventions.

  ## Guesser Points

      base(50) + speed_bonus + order_bonus

  - `speed_bonus = round(time_left / round_duration * 450)` → 0..450
  - `order_bonus`: 1st correct guesser **+50**, 2nd **+25**, others **+0**

  Total range: 50..550. No hint penalty — letter reveals do not reduce points.

  ## Drawer Points

  Drawer earns **floor(mean of guesser_points this round)**. If nobody guesses,
  drawer scores **0** (no timeout penalty).
  """

  @base_points 50
  @max_speed_bonus 450
  @order_bonuses %{1 => 50, 2 => 25}

  @doc """
  Calculate points for a correct guess.

  ## Parameters

  - `time_left` - seconds remaining when guess was made
  - `round_duration` - total round duration in seconds
  - `opts` - keyword list:
    - `:order` - 1-based guess order in this round. Default: 3 (no order bonus).
  """
  def guesser_points(time_left, round_duration, opts \\ []) do
    order = Keyword.get(opts, :order, 3)

    speed_bonus = round(@max_speed_bonus * time_left / max(round_duration, 1))
    order_bonus = Map.get(@order_bonuses, order, 0)

    @base_points + max(speed_bonus, 0) + order_bonus
  end

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

  @doc "Returns the maximum possible guesser points (base + max speed bonus + 1st-order bonus)."
  def max_points, do: @base_points + @max_speed_bonus + Map.get(@order_bonuses, 1, 0)

  @doc "Returns the order bonus for a given 1-based guess order."
  def order_bonus(order), do: Map.get(@order_bonuses, order, 0)
end
