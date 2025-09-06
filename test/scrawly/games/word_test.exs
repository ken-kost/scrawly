defmodule Scrawly.Games.WordTest do
  use Scrawly.DataCase

  alias Scrawly.Games

  describe "word selection" do
    test "get_random_word returns a word from the word list" do
      assert {:ok, word} = Games.get_random_word()
      assert is_binary(word)
      assert String.length(word) > 0
    end

    test "get_random_word returns different words on multiple calls" do
      words =
        for _ <- 1..10 do
          {:ok, word} = Games.get_random_word()
          word
        end

      # Should have some variety in 10 calls (not all the same word)
      unique_words = Enum.uniq(words)
      assert length(unique_words) > 1
    end

    test "word list contains exactly 100 words" do
      word_count = Games.get_word_count()
      assert word_count == 100
    end

    test "all words are valid strings" do
      {:ok, words} = Games.get_all_words()

      assert length(words) == 100

      Enum.each(words, fn word ->
        assert is_binary(word.text)
        assert String.length(word.text) > 0
        # Reasonable max length
        assert String.length(word.text) <= 20
        # Should only contain letters and spaces
        assert Regex.match?(~r/^[a-zA-Z\s]+$/, word.text)
      end)
    end
  end
end
