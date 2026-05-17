defmodule Scrawly.Games.WordTest do
  use Scrawly.DataCase

  alias Scrawly.Games

  setup do
    # Clear stale words from previous seeds, then re-seed with difficulty data
    {:ok, existing} = Games.get_all_words()
    Enum.each(existing, fn w -> Ash.destroy!(w) end)
    Scrawly.Games.Word.seed_words()
    :ok
  end

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

    test "word list contains words across all word counts" do
      word_count = Games.get_word_count()
      # 100 1-word + 100 2-word + 100 3-word = ~300 total
      assert word_count > 200
    end

    test "all words are valid strings" do
      {:ok, words} = Games.get_all_words()

      assert length(words) > 200

      Enum.each(words, fn word ->
        assert is_binary(word.text)
        assert String.length(word.text) > 0
        assert String.length(word.text) <= 60
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

  describe "difficulty categorization" do
    test "all words have a difficulty level" do
      {:ok, words} = Games.get_all_words()

      Enum.each(words, fn word ->
        assert word.difficulty in [:easy, :medium, :hard]
      end)
    end

    test "get_words_by_difficulty returns only words of requested difficulty" do
      {:ok, easy_words} = Games.get_words_by_difficulty(:easy)
      assert length(easy_words) > 0
      Enum.each(easy_words, fn w -> assert w.difficulty == :easy end)

      {:ok, medium_words} = Games.get_words_by_difficulty(:medium)
      assert length(medium_words) > 0
      Enum.each(medium_words, fn w -> assert w.difficulty == :medium end)

      {:ok, hard_words} = Games.get_words_by_difficulty(:hard)
      assert length(hard_words) > 0
      Enum.each(hard_words, fn w -> assert w.difficulty == :hard end)
    end

    test "difficulty counts include words across all word counts" do
      {:ok, easy} = Games.get_words_by_difficulty(:easy)
      {:ok, medium} = Games.get_words_by_difficulty(:medium)
      {:ok, hard} = Games.get_words_by_difficulty(:hard)

      # Each difficulty has entries across word_counts 1, 2, and 3
      assert length(easy) >= 60
      assert length(medium) >= 60
      assert length(hard) >= 60
    end
  end

  describe "word_count filtering" do
    test "get_words_by_difficulty_and_word_count filters correctly" do
      {:ok, one_word_easy} = Games.get_words_by_difficulty_and_word_count(:easy, 1)
      assert length(one_word_easy) == 30

      Enum.each(one_word_easy, fn w ->
        assert w.difficulty == :easy
        assert w.word_count == 1
      end)

      {:ok, two_word_medium} = Games.get_words_by_difficulty_and_word_count(:medium, 2)
      assert length(two_word_medium) > 0

      Enum.each(two_word_medium, fn w ->
        assert w.difficulty == :medium
        assert w.word_count == 2
        assert length(String.split(w.text)) == 2
      end)
    end

    test "get_random_word with word_count returns correct word count" do
      {:ok, word} = Games.get_random_word(word_count: 2)
      assert length(String.split(word)) == 2

      {:ok, word3} = Games.get_random_word(word_count: 3)
      assert length(String.split(word3)) == 3
    end
  end

  describe "smart word selection" do
    test "get_random_word with difficulty option returns word of that difficulty" do
      {:ok, word} = Games.get_random_word(difficulty: :easy, word_count: 1)
      {:ok, easy_words} = Games.get_words_by_difficulty_and_word_count(:easy, 1)
      easy_texts = Enum.map(easy_words, & &1.text)
      assert word in easy_texts
    end

    test "get_random_word excludes specified words" do
      # Get all 1-word easy words and exclude all but one
      {:ok, easy_words} = Games.get_words_by_difficulty_and_word_count(:easy, 1)
      all_but_last = easy_words |> Enum.map(& &1.text) |> Enum.drop(-1)

      {:ok, word} = Games.get_random_word(difficulty: :easy, word_count: 1, exclude: all_but_last)
      refute word in all_but_last
    end

    test "get_random_word falls back when all words excluded" do
      # Excluding everything should still return a word (falls back to unfiltered)
      {:ok, word} =
        Games.get_random_word(
          difficulty: :easy,
          word_count: 1,
          exclude: Scrawly.Games.Word.all_words_flat()
        )

      assert is_binary(word)
    end
  end
end
