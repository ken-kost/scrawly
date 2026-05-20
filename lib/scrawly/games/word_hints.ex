defmodule Scrawly.Games.WordHints do
  @moduledoc """
  Generates progressive hints for word guessing, modeled on skribbl.io.

  Reveals happen in **discrete batches** at fixed points in the round timeline.
  All reveal positions are picked once per word (deterministic via `:erlang.phash2/1`)
  so every client sees the same letters at the same time.

  ## Default schedule

  - Total letters to reveal: `floor(letter_count * 0.35)` (≈ 35% of letters)
  - Batches: 2 (split as evenly as possible)
  - Stage 0 (0%–37.5% elapsed): all underscores
  - Stage 1 (37.5%–68.75% elapsed): batch 1 revealed
  - Stage 2 (68.75%–100% elapsed): both batches revealed

  Spaces and hyphens are always rendered literally (never masked).
  """

  @default_schedule [0.375, 0.6875]
  @default_reveal_fraction 0.35

  # Characters that are always rendered literally (never masked).
  @always_visible [" ", "-"]

  @doc """
  Generate a hint display for a word. Returns a string with revealed letters and underscores.

  ## Options

  - `:hint_schedule` - list of floats; elapsed percentages where each batch becomes
    visible. Defaults to `[0.375, 0.6875]`.
  - `:reveal_fraction` - share of maskable letters to reveal across all batches.
    Defaults to `0.35`.
  """
  def generate_hint(word, time_left, round_duration \\ 60, opts \\ [])
  def generate_hint(nil, _, _, _), do: ""
  def generate_hint("", _, _, _), do: ""

  def generate_hint(word, time_left, round_duration, opts) when is_binary(word) do
    revealed = revealed_indices(word, time_left, round_duration, opts)
    render_hint(word, revealed)
  end

  @doc """
  Generate a fully hidden display (all underscores). Used for the initial display.
  """
  def hidden_display(word, round_duration \\ 60)
  def hidden_display(nil, _), do: ""
  def hidden_display("", _), do: ""

  def hidden_display(word, round_duration) when is_binary(word) do
    generate_hint(word, round_duration, round_duration)
  end

  @doc """
  Returns structured metadata about the current hint state.

  Map shape (stable for UI consumers):
  - `:stage` — 0, 1, ... up to number of batches (was named "stage" historically;
    now corresponds to the batch index that has been fully revealed)
  - `:revealed_count` — letters currently revealed
  - `:total_letters` — total maskable letters (spaces / hyphens excluded)
  - `:remaining_count` — letters still hidden
  - `:progress_pct` — percent of letters revealed (0..100)
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
  Returns the current hint stage (0..N) where N is the number of batches in the schedule.

  Stage 0 = nothing revealed. Stage N = all batches revealed.
  """
  def current_stage(time_left, round_duration, opts \\ []) do
    schedule = Keyword.get(opts, :hint_schedule, @default_schedule)
    elapsed_pct = 1.0 - time_left / max(round_duration, 1)

    Enum.reduce(schedule, 0, fn threshold, acc ->
      if elapsed_pct >= threshold, do: acc + 1, else: acc
    end)
  end

  @doc """
  Returns the number of letters in the word (excluding spaces and hyphens — always-visible chars).
  """
  def word_length_hint(word) when is_binary(word) do
    word
    |> String.graphemes()
    |> Enum.count(&(&1 not in @always_visible))
  end

  def word_length_hint(_), do: 0

  # ── Private ────────────────────────────────────────────────────────────

  defp render_hint(word, revealed) do
    word
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map(fn {char, idx} ->
      cond do
        char in @always_visible -> char
        MapSet.member?(revealed, idx) -> char
        true -> "_"
      end
    end)
    |> Enum.join(" ")
  end

  # Indices revealed so far based on time elapsed and the configured schedule.
  defp revealed_indices(word, time_left, round_duration, opts) do
    schedule = Keyword.get(opts, :hint_schedule, @default_schedule)
    fraction = Keyword.get(opts, :reveal_fraction, @default_reveal_fraction)
    stage = current_stage(time_left, round_duration, opts)

    if stage == 0 do
      MapSet.new()
    else
      batches = build_batches(word, length(schedule), fraction)

      batches
      |> Enum.take(stage)
      |> Enum.reduce(MapSet.new(), fn batch, acc -> MapSet.union(acc, batch) end)
    end
  end

  # Splits the chosen reveal indices into N batches (deterministic per word).
  defp build_batches(word, batch_count, fraction) when batch_count > 0 do
    target = reveal_target(word, fraction)
    indices = pick_reveal_indices(word, target)

    if indices == [] do
      List.duplicate(MapSet.new(), batch_count)
    else
      indices
      |> chunk_into(batch_count)
      |> Enum.map(&MapSet.new/1)
    end
  end

  defp reveal_target(word, fraction) do
    total = word_length_hint(word)
    target = floor(total * fraction)

    # Edge case: words with at least one maskable letter should reveal something
    # by the final batch.
    if total > 0 and target == 0, do: 1, else: target
  end

  # Deterministic shuffle of maskable indices using the word as seed, then take the
  # first `target` indices as our reveal set.
  defp pick_reveal_indices(word, target) when target > 0 do
    maskable =
      word
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reject(fn {char, _idx} -> char in @always_visible end)
      |> Enum.map(fn {_char, idx} -> idx end)

    seed = :erlang.phash2(word)

    maskable
    |> Enum.sort_by(fn idx -> :erlang.phash2({seed, idx}) end)
    |> Enum.take(target)
  end

  defp pick_reveal_indices(_word, _target), do: []

  # Splits a list into `n` chunks as evenly as possible. The earlier chunks absorb
  # any remainder so batch 1 has >= batch 2.
  defp chunk_into(list, n) when n > 0 do
    len = length(list)
    base_size = div(len, n)
    extra = rem(len, n)

    {chunks, _} =
      Enum.reduce(0..(n - 1), {[], list}, fn i, {acc, remaining} ->
        size = base_size + if(i < extra, do: 1, else: 0)
        {chunk, rest} = Enum.split(remaining, size)
        {[chunk | acc], rest}
      end)

    Enum.reverse(chunks)
  end
end
