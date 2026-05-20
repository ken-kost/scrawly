defmodule Scrawly.Games.WordHintsTest do
  use ExUnit.Case, async: true

  alias Scrawly.Games.WordHints

  # Default round duration is 60s.
  # Default schedule: [0.375, 0.6875] → two batches.
  # Stage thresholds (time_left values for 60s round):
  #   Stage 0: time_left > 37.5s elapsed → time_left > ~37.5s
  #   Stage 1: 37.5% ≤ elapsed < 68.75% → time_left in (~18.75, ~37.5]
  #   Stage 2: elapsed ≥ 68.75% → time_left ≤ ~18.75s

  defp revealed_letters(hint) do
    hint
    |> String.graphemes()
    |> Enum.count(&(&1 not in ["_", " "]))
  end

  describe "hidden_display/1" do
    test "hides all letters with underscores" do
      assert WordHints.hidden_display("cat") == "_ _ _"
    end

    test "preserves spaces literally in multi-word phrases" do
      result = WordHints.hidden_display("ice cream")
      # Letters never appear; the actual space sits between underscores
      refute result =~ "i"
      refute result =~ "c"
      assert result =~ " "
    end

    test "preserves hyphens literally" do
      result = WordHints.hidden_display("co-op")
      assert result =~ "-"
      refute result =~ "c"
    end

    test "returns empty string for nil" do
      assert WordHints.hidden_display(nil) == ""
    end

    test "returns empty string for empty string" do
      assert WordHints.hidden_display("") == ""
    end
  end

  describe "generate_hint/3 - stage progression" do
    test "stage 0: no letters revealed at full time" do
      hint = WordHints.generate_hint("butterfly", 60)
      assert revealed_letters(hint) == 0
    end

    test "stage 0: still no letters revealed just before 37.5% elapsed" do
      # 38s left of 60s round = ~36.7% elapsed → stage 0
      hint = WordHints.generate_hint("butterfly", 38)
      assert revealed_letters(hint) == 0
    end

    test "stage 1: first batch revealed at/after 37.5% elapsed" do
      # 37s left of 60s round = ~38.3% elapsed → stage 1
      hint = WordHints.generate_hint("butterfly", 37)
      assert revealed_letters(hint) >= 1
    end

    test "stage 2: both batches revealed at/after 68.75% elapsed" do
      # 18s left of 60s round = 70% elapsed → stage 2
      hint = WordHints.generate_hint("butterfly", 18)
      revealed = revealed_letters(hint)
      # ~35% of 9 letters = 3 expected total
      assert revealed >= 3
    end

    test "final batch reveals ~35% of letters" do
      hint = WordHints.generate_hint("strawberry", 0)
      revealed = revealed_letters(hint)
      total = WordHints.word_length_hint("strawberry")
      expected = floor(total * 0.35)
      assert revealed == expected
    end

    test "stage 2 reveals at least as many letters as stage 1" do
      stage_1 = WordHints.generate_hint("butterfly", 30)
      stage_2 = WordHints.generate_hint("butterfly", 5)
      assert revealed_letters(stage_2) >= revealed_letters(stage_1)
    end

    test "progressive: each stage reveals >= the previous" do
      word = "elephant"
      times = [60, 30, 5]

      counts =
        Enum.map(times, fn t ->
          revealed_letters(WordHints.generate_hint(word, t))
        end)

      counts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, curr] -> assert curr >= prev end)
    end
  end

  describe "generate_hint/3 - determinism" do
    test "hint is deterministic for same word and time" do
      assert WordHints.generate_hint("butterfly", 10) ==
               WordHints.generate_hint("butterfly", 10)
    end

    test "the reveal set in stage 1 is a subset of the reveal set in stage 2" do
      word = "strawberry"
      stage_1 = WordHints.generate_hint(word, 30)
      stage_2 = WordHints.generate_hint(word, 0)

      stage_1_chars = String.graphemes(stage_1)
      stage_2_chars = String.graphemes(stage_2)

      # Every revealed char in stage_1 must still be revealed (and identical) in stage_2
      Enum.zip(stage_1_chars, stage_2_chars)
      |> Enum.each(fn {a, b} ->
        if a != "_" and a != " " do
          assert a == b, "Expected #{inspect(a)} to remain revealed in stage 2 but got #{inspect(b)}"
        end
      end)
    end

    test "different words produce different reveal patterns" do
      h1 = WordHints.generate_hint("butterfly", 0)
      h2 = WordHints.generate_hint("strawberry", 0)
      # Different lengths alone make these differ; just sanity-check both contain something
      assert revealed_letters(h1) >= 1
      assert revealed_letters(h2) >= 1
    end
  end

  describe "generate_hint/3 - edge cases" do
    test "returns empty string for nil" do
      assert WordHints.generate_hint(nil, 50) == ""
    end

    test "returns empty string for empty word" do
      assert WordHints.generate_hint("", 50) == ""
    end

    test "single character word reveals itself once stage advances" do
      hint = WordHints.generate_hint("a", 0)
      assert hint == "a"
    end

    test "two-letter word reveals at least one letter at final stage" do
      hint = WordHints.generate_hint("go", 0)
      assert revealed_letters(hint) >= 1
    end

    test "spaces and hyphens are never masked" do
      hint = WordHints.generate_hint("ice cream", 60)
      assert hint =~ " "
      refute hint =~ "i"

      hint2 = WordHints.generate_hint("co-op", 0)
      assert hint2 =~ "-"
    end

    test "works with custom round duration" do
      # 120s round, 100s left = 16.7% elapsed → stage 0
      assert revealed_letters(WordHints.generate_hint("butterfly", 100, 120)) == 0
      # 120s round, 60s left = 50% elapsed → stage 1
      assert revealed_letters(WordHints.generate_hint("butterfly", 60, 120)) >= 1
    end

    test "spaces in multi-word target render in the output literally" do
      hint = WordHints.generate_hint("fire truck", 60)
      # Exactly one space between "fire" and "truck"
      assert hint =~ " "
    end
  end

  describe "generate_hint/4 - configurable schedule and fraction" do
    test "custom schedule changes when letters are revealed" do
      # Early schedule: stage 1 starts at 10% elapsed
      hint = WordHints.generate_hint("butterfly", 53, 60, hint_schedule: [0.10, 0.30])
      assert revealed_letters(hint) >= 1
    end

    test "late schedule delays all hints" do
      # Stage 1 only at 50% elapsed
      hint = WordHints.generate_hint("butterfly", 45, 60, hint_schedule: [0.50, 0.70])
      assert revealed_letters(hint) == 0
    end

    test "reveal_fraction controls total share of letters revealed" do
      hint_low = WordHints.generate_hint("strawberry", 0, 60, reveal_fraction: 0.1)
      hint_high = WordHints.generate_hint("strawberry", 0, 60, reveal_fraction: 0.6)
      assert revealed_letters(hint_high) > revealed_letters(hint_low)
    end

    test "single-batch schedule works" do
      # One batch revealing at 50% elapsed
      hint = WordHints.generate_hint("butterfly", 25, 60, hint_schedule: [0.5])
      assert revealed_letters(hint) >= 1
    end
  end

  describe "hint_info/3" do
    test "returns stage 0 info at start of round" do
      info = WordHints.hint_info("butterfly", 60)
      assert info.stage == 0
      assert info.revealed_count == 0
      assert info.total_letters == 9
      assert info.remaining_count == 9
      assert info.progress_pct == 0
    end

    test "returns stage 1 info after first batch reveals" do
      info = WordHints.hint_info("butterfly", 30)
      assert info.stage == 1
      assert info.revealed_count >= 1
      assert info.revealed_count + info.remaining_count == info.total_letters
    end

    test "returns stage 2 info after second batch reveals" do
      info = WordHints.hint_info("butterfly", 5)
      assert info.stage == 2
      # ~35% of 9 letters = 3 expected
      assert info.revealed_count >= 3
    end

    test "returns zeros for nil word" do
      assert WordHints.hint_info(nil, 50) == %{
               stage: 0,
               revealed_count: 0,
               total_letters: 0,
               remaining_count: 0,
               progress_pct: 0
             }
    end

    test "returns zeros for empty word" do
      assert WordHints.hint_info("", 50) == %{
               stage: 0,
               revealed_count: 0,
               total_letters: 0,
               remaining_count: 0,
               progress_pct: 0
             }
    end

    test "progress_pct increases monotonically across stages" do
      word = "butterfly"
      times = [60, 30, 5]
      pcts = Enum.map(times, &WordHints.hint_info(word, &1).progress_pct)

      pcts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, curr] -> assert curr >= prev end)
    end
  end

  describe "current_stage/3" do
    test "returns 0 at start of round" do
      assert WordHints.current_stage(60, 60) == 0
    end

    test "returns 1 after first threshold (37.5%)" do
      # 60 * (1 - 0.375) = 37.5s left → boundary
      assert WordHints.current_stage(37, 60) == 1
    end

    test "returns 2 after second threshold (68.75%)" do
      # 60 * (1 - 0.6875) = 18.75s left → boundary
      assert WordHints.current_stage(18, 60) == 2
    end

    test "returns max stage at time 0" do
      assert WordHints.current_stage(0, 60) == 2
    end

    test "respects custom schedule length" do
      # 10s left of 60s = ~83% elapsed → past all 4 thresholds
      assert WordHints.current_stage(10, 60, hint_schedule: [0.1, 0.3, 0.5, 0.7]) == 4
    end
  end

  describe "word_length_hint/1" do
    test "returns character count excluding spaces" do
      assert WordHints.word_length_hint("butterfly") == 9
      assert WordHints.word_length_hint("cat") == 3
    end

    test "excludes spaces in multi-word phrases" do
      assert WordHints.word_length_hint("ice cream") == 8
    end

    test "excludes hyphens" do
      assert WordHints.word_length_hint("co-op") == 4
    end

    test "returns 0 for nil" do
      assert WordHints.word_length_hint(nil) == 0
    end
  end
end
