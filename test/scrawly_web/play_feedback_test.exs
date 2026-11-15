defmodule ScrawlyWeb.PlayFeedbackTest do
  @moduledoc """
  The game page's play-feedback text (`ScrawlyWeb.PlayFeedback`): blanks as
  one block per word, the "3 words · 11 letters" label, "you got it", the
  close-guess line and the round summary's points.
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
