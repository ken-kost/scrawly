defmodule ScrawlyWeb.PlayFeedbackTest do
  @moduledoc """
  The game page's play-feedback text (`ScrawlyWeb.PlayFeedback`): blanks as
  one block per word, the "3 words · 11 letters" label, "you got it", the
  close-guess line, the round summary's points and the difficulty chip.
  """
  use ExUnit.Case, async: true

  alias Scrawly.Games.WordHints
  alias ScrawlyWeb.PlayFeedback

  doctest PlayFeedback

  describe "mask_blocks/1" do
    test "one block per word of the room's mask, at every hint stage" do
      for word <- ["chicken crossing the road", "butterflies in the stomach", "bird's nest"],
          stage <- [0, 1, 2] do
        mask = WordHints.hint_for_stage(word, stage)
        blocks = PlayFeedback.mask_blocks(mask)

        assert length(blocks) == length(String.split(word, " "))
        # Each block is its word's mask: as many characters, no word gap.
        for {block, w} <- Enum.zip(blocks, String.split(word, " ")) do
          assert String.length(String.replace(block, " ", "")) == String.length(w)
          refute block =~ "  "
        end

        # The blocks rebuild the mask.
        assert Enum.join(blocks, "   ") == mask
      end
    end

    test "keeps revealed letters, hyphens and apostrophes in their word" do
      assert PlayFeedback.mask_blocks("_ _ _ _ ' _   n _ _ _") == ["_ _ _ _ ' _", "n _ _ _"]
      assert PlayFeedback.mask_blocks("_ - _ _ _ _ _") == ["_ - _ _ _ _ _"]
      assert PlayFeedback.mask_blocks(nil) == []
    end
  end

  describe "word_view/1" do
    test "the blocks and the label of every word the page shows, from one set of inputs" do
      inputs = %{
        display: "_ _ _   _ _ _ _ _",
        letters: 8,
        word: "chicken run",
        revealed: nil,
        summary: "bird's nest"
      }

      assert PlayFeedback.word_view(inputs) == %{
               for: inputs,
               mask: ["_ _ _", "_ _ _ _ _"],
               label: "2 words · 8 letters",
               word: ["CHICKEN", "RUN"],
               revealed: [],
               summary: ["BIRD'S", "NEST"]
             }
    end

    test "nothing to show is empty blocks" do
      view =
        PlayFeedback.word_view(%{
          display: nil,
          letters: nil,
          word: nil,
          revealed: nil,
          summary: nil
        })

      assert view.mask == [] and view.word == [] and view.revealed == [] and view.summary == []
      assert view.label == "0 letters"
    end
  end

  describe "difficulty_label/1 and difficulty_class/1" do
    test "each difficulty reads with its points bonus; an AI word has no chip" do
      assert Enum.map([:easy, :medium, :hard, nil], &PlayFeedback.difficulty_label/1) ==
               ["easy", "medium · +25%", "hard · +50%", nil]

      for junk <- ["hard", :extreme, 3], do: assert(PlayFeedback.difficulty_label(junk) == nil)
    end

    test "chips reuse the chip styles, plainer for easier words" do
      assert PlayFeedback.difficulty_class(:easy) == "chip difficulty-chip"
      assert PlayFeedback.difficulty_class(:medium) == "chip chip-strong difficulty-chip"
      assert PlayFeedback.difficulty_class(:hard) == "chip chip-accent difficulty-chip"
    end
  end

  describe "word_label/2" do
    test "words and letters for a phrase, letters alone for a single word" do
      label = fn word ->
        PlayFeedback.word_label(
          WordHints.hint_for_stage(word, 0),
          WordHints.word_length_hint(word)
        )
      end

      assert label.("popcorn") == "7 letters"
      assert label.("t-shirt") == "6 letters"
      assert label.("ice cream") == "2 words · 8 letters"
      assert label.("knight in shining armor") == "4 words · 20 letters"
      assert label.("bird's nest") == "2 words · 9 letters"
      assert PlayFeedback.word_label("_", 1) == "1 letter"
      assert PlayFeedback.word_label("", 0) == "0 letters"
    end
  end

  test "guessed?/3: listed by the room, or the user's own reply came first" do
    assert PlayFeedback.guessed?(["u1"], "u1", nil)
    assert PlayFeedback.guessed?([], "u1", 300)
    refute PlayFeedback.guessed?(["u2"], "u1", nil)
    refute PlayFeedback.guessed?(["u1"], nil, nil)
    refute PlayFeedback.guessed?(nil, "u1", nil)
  end
end
