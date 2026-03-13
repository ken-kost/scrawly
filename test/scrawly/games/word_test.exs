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

      unique_words = Enum.uniq(words)
      assert length(unique_words) > 1
    end

    test "word list has words from all difficulties" do
      word_count = Games.get_word_count()
      assert word_count >= 100
    end

    test "all words are valid strings" do
      {:ok, words} = Games.get_all_words()

      assert length(words) >= 100

      Enum.each(words, fn word ->
        assert is_binary(word.text)
        assert String.length(word.text) > 0
        assert String.length(word.text) <= 20
        assert Regex.match?(~r/^[a-zA-Z\s]+$/, word.text)
      end)
    end

    test "words have difficulty attribute" do
      {:ok, words} = Games.get_all_words()

      Enum.each(words, fn word ->
        assert word.difficulty in [:easy, :medium, :hard]
      end)
    end

    test "get_random_word with easy difficulty returns easy words" do
      {:ok, words} = Games.list_words_by_difficulty(:easy)
      easy_texts = Enum.map(words, & &1.text)

      for _ <- 1..10 do
        {:ok, word} = Games.get_random_word(difficulty: :easy)
        assert word in easy_texts
      end
    end

    test "get_random_word with medium difficulty returns medium words" do
      {:ok, words} = Games.list_words_by_difficulty(:medium)
      medium_texts = Enum.map(words, & &1.text)

      for _ <- 1..10 do
        {:ok, word} = Games.get_random_word(difficulty: :medium)
        assert word in medium_texts
      end
    end

    test "get_random_word with hard difficulty returns hard words" do
      {:ok, words} = Games.list_words_by_difficulty(:hard)
      hard_texts = Enum.map(words, & &1.text)

      for _ <- 1..10 do
        {:ok, word} = Games.get_random_word(difficulty: :hard)
        assert word in hard_texts
      end
    end
  end

  describe "hint generation" do
    test "generate_hint returns underscores for each letter" do
      hint = Games.generate_hint("cat")
      assert hint == "_ _ _"
    end

    test "generate_hint handles multi-word phrases" do
      hint = Games.generate_hint("ice cream")
      assert hint == "_ _ _    _ _ _ _ _"
    end

    test "generate_hint handles single letter words" do
      hint = Games.generate_hint("a")
      assert hint == "_"
    end

    test "obfuscate_word returns hint" do
      result = Games.obfuscate_word("test", "some-user-id")
      assert result == "_ _ _ _"
    end
  end

  describe "scoring" do
    test "calculate_points returns correct values" do
      assert Games.calculate_points(80) == 200
      assert Games.calculate_points(40) == 150
      assert Games.calculate_points(0) == 100
    end

    test "calculate_points with time remaining gives bonus" do
      points = Games.calculate_points(60)
      assert points == 175
    end
  end
end
