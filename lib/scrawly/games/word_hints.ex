defmodule Scrawly.Games.WordHints do
  @moduledoc """
  Generates progressive hints for word guessing.
  Reveals letters based on elapsed time in the round.

  ## Hint Stages

  The hint system uses 5 progressive stages, each triggered at a percentage
  of the round duration elapsed:

  | Stage | Time Elapsed | Revealed                                        |
  |-------|-------------|--------------------------------------------------|
  | 0     | 0% - 25%    | All underscores (no hints)                       |
  | 1     | 25% - 50%   | First letter                                     |
  | 2     | 50% - 65%   | First + last letter                              |
  | 3     | 65% - 80%   | First + last + ~25% of middle letters (vowels)   |
  | 4     | 80% - 100%  | First + last + ~50% of middle letters             |

  ## Configurable Schedule

  Pass a custom `hint_schedule` option to change when stages trigger:

      WordHints.generate_hint("butterfly", 30, 60, hint_schedule: [0.25, 0.40, 0.55, 0.70])

  ## Hint Metadata

  Use `hint_info/3` to get structured metadata for UI display:

      %{stage: 3, revealed_count: 5, total_letters: 9, remaining_count: 4, progress_pct: 56}
  """

  @default_schedule [0.25, 0.50, 0.65, 0.80]

  @doc """
  Generate a hint display for a word. Returns a string with revealed letters and underscores.

  ## Options

  - `hint_schedule` - list of 4 floats representing the % of round elapsed when each
    stage triggers. Default: `[0.25, 0.50, 0.65, 0.80]`.
  """
  def generate_hint(word, time_left, round_duration \\ 60, opts \\ [])

  def generate_hint(nil, _, _, _), do: ""
  def generate_hint("", _, _, _), do: ""

  def generate_hint(word, time_left, round_duration, opts)
      when is_binary(word) and is_integer(time_left) do
    revealed = revealed_indices(word, time_left, round_duration, opts)
    render_hint(word, revealed)
  end

  @doc """
  Generate a fully hidden display (all underscores). Used for initial display.
  """
  def hidden_display(word, round_duration \\ 60)
  def hidden_display(nil, _), do: ""
  def hidden_display("", _), do: ""

  def hidden_display(word, round_duration) when is_binary(word) do
    generate_hint(word, round_duration, round_duration)
  end

  @doc """
  Returns structured metadata about the current hint state.

  Useful for UI elements like hint progress indicators and remaining letter counters.

  Returns:
  - `stage` - current hint stage (0-4)
  - `revealed_count` - number of letters currently revealed
  - `total_letters` - total number of letters in the word (excluding spaces)
  - `remaining_count` - letters still hidden
  - `progress_pct` - percentage of letters revealed (0-100)
  """
  def hint_info(word, time_left, round_duration \\ 60, opts \\ [])

  def hint_info(nil, _, _, _),
    do: %{stage: 0, revealed_count: 0, total_letters: 0, remaining_count: 0, progress_pct: 0}

  def hint_info("", _, _, _),
    do: %{stage: 0, revealed_count: 0, total_letters: 0, remaining_count: 0, progress_pct: 0}

  def hint_info(word, time_left, round_duration, opts) when is_binary(word) do
    revealed = revealed_indices(word, time_left, round_duration, opts)
    total = word_length_hint(word)
    revealed_count = MapSet.size(revealed)
    stage = current_stage(time_left, round_duration, opts)

    %{
      stage: stage,
      revealed_count: revealed_count,
      total_letters: total,
      remaining_count: total - revealed_count,
      progress_pct: if(total > 0, do: round(revealed_count * 100 / total), else: 0)
    }
  end

  @doc """
  Returns the current hint stage (0-4) based on time remaining.
  """
  def current_stage(time_left, round_duration, opts \\ []) do
    schedule = Keyword.get(opts, :hint_schedule, @default_schedule)
    elapsed_pct = 1.0 - time_left / max(round_duration, 1)

    [t1, t2, t3, t4] = schedule

    cond do
      elapsed_pct < t1 -> 0
      elapsed_pct < t2 -> 1
      elapsed_pct < t3 -> 2
      elapsed_pct < t4 -> 3
      true -> 4
    end
  end

  @doc """
  Returns the number of letters in the word (excluding spaces).
  """
  def word_length_hint(word) when is_binary(word) do
    word
    |> String.graphemes()
    |> Enum.count(&(&1 != " "))
  end

  def word_length_hint(_), do: 0

  # ── Private ────────────────────────────────────────────────────────────

  defp render_hint(word, revealed) do
    word
    |> String.split(" ")
    |> Enum.with_index()
    |> Enum.map(fn {sub_word, word_idx} ->
      offset =
        word |> String.split(" ") |> Enum.take(word_idx) |> Enum.join(" ") |> String.length()

      offset = if word_idx > 0, do: offset + 1, else: offset

      sub_word
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {char, i} ->
        if MapSet.member?(revealed, offset + i), do: char, else: "_"
      end)
      |> Enum.join(" ")
    end)
    |> Enum.join("  /  ")
  end

  # Determine which character indices should be revealed based on time_left.
  defp revealed_indices(word, time_left, round_duration, opts) do
    graphemes = String.graphemes(word)
    letter_indices = letter_indices(graphemes)
    stage = current_stage(time_left, round_duration, opts)

    case stage do
      0 ->
        MapSet.new()

      1 ->
        first_letter_set(letter_indices)

      2 ->
        MapSet.union(first_letter_set(letter_indices), last_letter_set(letter_indices))

      3 ->
        first_last =
          MapSet.union(first_letter_set(letter_indices), last_letter_set(letter_indices))

        middle = select_middle_letters(word, letter_indices, first_last, 0.25)
        MapSet.union(first_last, middle)

      4 ->
        first_last =
          MapSet.union(first_letter_set(letter_indices), last_letter_set(letter_indices))

        middle = select_middle_letters(word, letter_indices, first_last, 0.50)
        MapSet.union(first_last, middle)
    end
  end

  # Returns indices of all non-space characters.
  defp letter_indices(graphemes) do
    graphemes
    |> Enum.with_index()
    |> Enum.filter(fn {char, _idx} -> char != " " end)
    |> Enum.map(fn {_char, idx} -> idx end)
  end

  defp first_letter_set([]), do: MapSet.new()
  defp first_letter_set(letter_indices), do: MapSet.new([List.first(letter_indices)])

  defp last_letter_set([]), do: MapSet.new()
  defp last_letter_set(letter_indices), do: MapSet.new([List.last(letter_indices)])

  # Select a fraction of middle letters, prioritizing vowels.
  # Uses the word itself for deterministic ordering so hints stay consistent.
  defp select_middle_letters(word, letter_indices, already_revealed, fraction) do
    graphemes = String.graphemes(word)

    middle_indices =
      Enum.reject(letter_indices, fn idx -> MapSet.member?(already_revealed, idx) end)

    count = max(1, round(length(middle_indices) * fraction))

    # Prioritize vowels — they're more helpful for guessing
    {vowel_indices, consonant_indices} =
      Enum.split_with(middle_indices, fn idx ->
        char = Enum.at(graphemes, idx)
        char && String.downcase(char) in ~w(a e i o u)
      end)

    # Deterministic shuffle using word hash
    seed = :erlang.phash2(word)
    sorted_vowels = deterministic_sort(vowel_indices, seed)
    sorted_consonants = deterministic_sort(consonant_indices, seed + 1)

    # Take vowels first, then consonants up to count
    candidates = sorted_vowels ++ sorted_consonants
    MapSet.new(Enum.take(candidates, count))
  end

  # Produces a deterministic ordering of indices based on a seed.
  defp deterministic_sort(indices, seed) do
    Enum.sort_by(indices, fn idx -> :erlang.phash2({seed, idx}) end)
  end
end
