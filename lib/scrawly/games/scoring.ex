defmodule Scrawly.Games.Scoring do
  @moduledoc """
  Scoring calculations for Scrawly game rounds.

  ## Guesser Points

  Points are awarded on a curve that rewards faster guessing:

      base(50) + speed_bonus(time_left, round_duration)

  Where `speed_bonus = time_left / round_duration * 450`, yielding a range of **50-500**.

  A hint penalty reduces the guesser's points based on how many letters were revealed
  when they guessed. Each revealed letter reduces points by a percentage.

  ## Drawer Points

  The drawer earns **+50 points per correct guesser**. If nobody guesses before time
  runs out, the drawer receives a flat **-25 penalty** (reduced from old -80).

  When all guessers guess correctly, the drawer gets a **+100 bonus** on top of
  per-guesser points.

  ## Summary Table

  | Event                      | Points         | Notes                          |
  |---------------------------|----------------|--------------------------------|
  | Correct guess (guesser)   | 50-500         | Speed curve, reduced by hints  |
  | Per guesser (drawer)      | +50            | Per each correct guesser       |
  | All guessed bonus (drawer)| +100           | Extra bonus when everyone gets it |
  | Time up, some guessed     | per-guesser    | No penalty, just per-guesser   |
  | Time up, nobody guessed   | -25            | Flat penalty for drawer        |
  """

  alias Scrawly.Games.WordHints

  @base_points 50
  @max_speed_bonus 450
  @drawer_per_guesser 50
  @drawer_all_guessed_bonus 100
  @drawer_timeout_penalty -25

  @doc """
  Calculate points for a correct guess.

  Returns an integer in the range 50-500 (before hint penalty).

  ## Parameters

  - `time_left` - seconds remaining when guess was made
  - `round_duration` - total round duration in seconds
  - `opts` - keyword list:
    - `hint_stage` - current hint stage (0-4), reduces points. Default: 0.
  """
  def guesser_points(time_left, round_duration, opts \\ []) do
    hint_stage = Keyword.get(opts, :hint_stage, 0)

    speed_bonus = round(@max_speed_bonus * time_left / max(round_duration, 1))
    raw = @base_points + speed_bonus

    # Each hint stage beyond 0 reduces points by 10%
    reduction = hint_stage * 0.10
    reduced = round(raw * (1.0 - reduction))

    # Floor at base points — you always get at least 50
    max(reduced, @base_points)
  end

  @doc """
  Calculate drawer points for a round.

  ## Parameters

  - `correct_count` - number of players who guessed correctly
  - `total_guessers` - total number of non-drawer players
  - `opts` - keyword list:
    - `time_up` - whether the round ended by timeout. Default: false.
  """
  def drawer_points(correct_count, total_guessers, opts \\ []) do
    time_up = Keyword.get(opts, :time_up, false)

    cond do
      correct_count == 0 and time_up ->
        @drawer_timeout_penalty

      correct_count == 0 ->
        0

      correct_count >= total_guessers and total_guessers > 0 ->
        correct_count * @drawer_per_guesser + @drawer_all_guessed_bonus

      true ->
        correct_count * @drawer_per_guesser
    end
  end

  @doc """
  Convenience: compute guesser points using current word and time state.
  Automatically determines hint stage from WordHints.
  """
  def guesser_points_with_hints(time_left, round_duration, _word) do
    stage = WordHints.current_stage(time_left, round_duration)
    guesser_points(time_left, round_duration, hint_stage: stage)
  end

  @doc "Returns the base points constant (minimum guesser points)."
  def base_points, do: @base_points

  @doc "Returns the maximum possible guesser points (base + max speed bonus)."
  def max_points, do: @base_points + @max_speed_bonus

  @doc "Returns the per-guesser drawer reward."
  def drawer_per_guesser, do: @drawer_per_guesser

  @doc "Returns the drawer timeout penalty."
  def drawer_timeout_penalty, do: @drawer_timeout_penalty
end
