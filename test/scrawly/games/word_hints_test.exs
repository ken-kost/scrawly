defmodule Scrawly.Games.WordHintsTest do
  use ExUnit.Case, async: true

  alias Scrawly.Games.WordHints

  # Default round duration is 60s.
  # Default schedule: [0.25, 0.50, 0.65, 0.80]
  # Stage thresholds (time_left values for 60s round):
  #   Stage 0: time_left > 45s  (0-25% elapsed)
  #   Stage 1: time_left 30-45s (25-50% elapsed)
  #   Stage 2: time_left 21-30s (50-65% elapsed)
  #   Stage 3: time_left 12-21s (65-80% elapsed)
  #   Stage 4: time_left 0-12s  (80-100% elapsed)

  describe "hidden_display/1" do
    test "hides all letters with underscores" do
      assert WordHints.hidden_display("cat") == "_ _ _"
    end

    test "preserves spaces in multi-word phrases with visible separator" do
      result = WordHints.hidden_display("ice cream")
      assert result =~ "/"
      refute result =~ "i"
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
    test "stage 0: no letters revealed at start of round (60s left)" do
      hint = WordHints.generate_hint("butterfly", 60)
      refute hint =~ "b"
      refute hint =~ "y"
      assert hint =~ "_"
    end

    test "stage 0: no letters revealed above 25% elapsed (46s left)" do
      hint = WordHints.generate_hint("butterfly", 46)
      refute hint =~ "b"
      refute hint =~ "y"
    end

    test "stage 1: first letter revealed at 25% elapsed (45s left)" do
      hint = WordHints.generate_hint("butterfly", 45)
      assert String.starts_with?(hint, "b")
      refute hint =~ "y"
    end

    test "stage 1: first letter revealed between 25%-50% (31s left)" do
      hint = WordHints.generate_hint("butterfly", 31)
      assert String.starts_with?(hint, "b")
    end

    test "stage 2: first and last letter revealed at 50% elapsed (30s left)" do
      hint = WordHints.generate_hint("butterfly", 30)
      assert String.starts_with?(hint, "b")
      assert String.ends_with?(hint, "y")
    end

    test "stage 3: additional middle letters revealed at 65% elapsed (21s left)" do
      hint = WordHints.generate_hint("butterfly", 21)
      assert String.starts_with?(hint, "b")
      assert String.ends_with?(hint, "y")
      revealed = hint |> String.graphemes() |> Enum.count(&(&1 != "_" and &1 != " "))
      # first + last + ~25% of middle = at least 3, typically more for longer words
      assert revealed >= 3
    end

    test "stage 4: ~50% of middle letters revealed at 80% elapsed (12s left)" do
      hint = WordHints.generate_hint("butterfly", 12)
      assert String.starts_with?(hint, "b")
      assert String.ends_with?(hint, "y")
      revealed = hint |> String.graphemes() |> Enum.count(&(&1 != "_" and &1 != " "))
      # More letters revealed than stage 3
      assert revealed >= 4
    end

    test "stage 4 reveals more than stage 3" do
      hint_stage3 = WordHints.generate_hint("butterfly", 18)
      hint_stage4 = WordHints.generate_hint("butterfly", 5)

      revealed_3 = hint_stage3 |> String.graphemes() |> Enum.count(&(&1 != "_" and &1 != " "))
      revealed_4 = hint_stage4 |> String.graphemes() |> Enum.count(&(&1 != "_" and &1 != " "))

      assert revealed_4 >= revealed_3
    end

    test "progressive: each stage reveals at least as many letters as the previous" do
      word = "elephant"
      times = [60, 45, 30, 18, 5]

      revealed_counts =
        Enum.map(times, fn t ->
          hint = WordHints.generate_hint(word, t)
          hint |> String.graphemes() |> Enum.count(&(&1 != "_" and &1 != " "))
        end)

      # Each stage should reveal >= the previous stage
      revealed_counts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, curr] ->
        assert curr >= prev
      end)
    end
  end

  describe "generate_hint/3 - vowel priority" do
    test "stage 3 preferentially reveals vowels in longer words" do
      # "strawberry" has vowels: a(3), e(8)
      hint = WordHints.generate_hint("strawberry", 18)

      # The revealed middle letters should include at least one vowel
      graphemes = String.graphemes("strawberry")
      hint_chars = hint |> String.split(" ") |> Enum.join("") |> String.graphemes()

      revealed_middles =
        Enum.zip(graphemes, hint_chars)
        |> Enum.with_index()
        |> Enum.filter(fn {{_orig, shown}, idx} -> shown != "_" and idx > 0 and idx < 9 end)
        |> Enum.map(fn {{orig, _}, _} -> orig end)

      has_vowel = Enum.any?(revealed_middles, &(&1 in ~w(a e i o u)))
      # With vowel priority, we expect at least one vowel to be revealed
      assert has_vowel or length(revealed_middles) == 0
    end
  end

  describe "generate_hint/3 - determinism and edge cases" do
    test "hint is deterministic for same word and time" do
      hint1 = WordHints.generate_hint("butterfly", 10)
      hint2 = WordHints.generate_hint("butterfly", 10)
      assert hint1 == hint2
    end

    test "returns empty string for nil word" do
      assert WordHints.generate_hint(nil, 50) == ""
    end

    test "works with short words" do
      hint = WordHints.generate_hint("cat", 25)
      assert String.starts_with?(hint, "c")
      assert String.ends_with?(hint, "t")
    end

    test "works with single character" do
      hint = WordHints.generate_hint("a", 40)
      assert hint == "a"
    end

    test "works with two-letter word" do
      # Stage 2: first and last revealed = entire word
      hint = WordHints.generate_hint("go", 25)
      assert hint == "g o"
    end

    test "works with custom round duration" do
      # 120s round with default schedule:
      # Stage 1 starts at 25% elapsed = 90s left
      hint_start = WordHints.generate_hint("butterfly", 100, 120)
      refute hint_start =~ "b"

      hint_mid = WordHints.generate_hint("butterfly", 85, 120)
      assert String.starts_with?(hint_mid, "b")
    end

    test "multi-word hints show separator between words" do
      hint = WordHints.generate_hint("fire truck", 60)
      assert hint =~ "/"
    end
  end

  describe "generate_hint/4 - configurable schedule" do
    test "custom schedule changes when letters are revealed" do
      # Early schedule: hints start at 10% elapsed (54s left for 60s round)
      early_schedule = [0.10, 0.30, 0.50, 0.70]
      hint = WordHints.generate_hint("butterfly", 53, 60, hint_schedule: early_schedule)
      assert String.starts_with?(hint, "b")
    end

    test "late schedule delays all hints" do
      late_schedule = [0.50, 0.70, 0.85, 0.95]
      # At 25% elapsed (45s left), should still be stage 0
      hint = WordHints.generate_hint("butterfly", 45, 60, hint_schedule: late_schedule)
      refute hint =~ "b"
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

    test "returns stage 1 info when first letter revealed" do
      info = WordHints.hint_info("butterfly", 40)
      assert info.stage == 1
      assert info.revealed_count == 1
      assert info.remaining_count == 8
      assert info.progress_pct == round(1 * 100 / 9)
    end

    test "returns stage 2 info when first and last revealed" do
      info = WordHints.hint_info("butterfly", 25)
      assert info.stage == 2
      assert info.revealed_count == 2
      assert info.remaining_count == 7
    end

    test "stage 3 reveals more letters for longer words" do
      info = WordHints.hint_info("strawberry", 18)
      assert info.stage == 3
      assert info.revealed_count >= 3
    end

    test "stage 4 reveals the most letters" do
      info = WordHints.hint_info("butterfly", 5)
      assert info.stage == 4
      assert info.revealed_count >= 4
    end

    test "returns zeros for nil word" do
      info = WordHints.hint_info(nil, 50)

      assert info == %{
               stage: 0,
               revealed_count: 0,
               total_letters: 0,
               remaining_count: 0,
               progress_pct: 0
             }
    end

    test "returns zeros for empty word" do
      info = WordHints.hint_info("", 50)

      assert info == %{
               stage: 0,
               revealed_count: 0,
               total_letters: 0,
               remaining_count: 0,
               progress_pct: 0
             }
    end

    test "progress_pct increases across stages" do
      word = "butterfly"
      times = [60, 40, 25, 18, 5]
      pcts = Enum.map(times, fn t -> WordHints.hint_info(word, t).progress_pct end)

      pcts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, curr] -> assert curr >= prev end)
    end
  end

  describe "current_stage/3" do
    test "returns 0 at start of round" do
      assert WordHints.current_stage(60, 60) == 0
    end

    test "returns 1 after 25% elapsed" do
      assert WordHints.current_stage(44, 60) == 1
    end

    test "returns 2 after 50% elapsed" do
      assert WordHints.current_stage(29, 60) == 2
    end

    test "returns 3 after 65% elapsed" do
      assert WordHints.current_stage(20, 60) == 3
    end

    test "returns 4 after 80% elapsed" do
      assert WordHints.current_stage(11, 60) == 4
    end

    test "returns 4 at time 0" do
      assert WordHints.current_stage(0, 60) == 4
    end

    test "respects custom schedule" do
      assert WordHints.current_stage(50, 60, hint_schedule: [0.10, 0.30, 0.50, 0.70]) == 1
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

    test "returns 0 for nil" do
      assert WordHints.word_length_hint(nil) == 0
    end
  end
end
