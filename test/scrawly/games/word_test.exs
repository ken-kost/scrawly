defmodule Scrawly.Games.WordTest do
  use Scrawly.DataCase

  alias Scrawly.Games
  alias Scrawly.Games.{AnswerKind, Word, WordList}

  setup do
    Games.sync_words()
    :ok
  end

  # Entries of the word file of a kind (:word or :phrase) and difficulty.
  defp file_count(difficulty, kind) do
    Enum.count(
      WordList.entries(),
      &(&1.difficulty == difficulty and AnswerKind.of(&1.text) == kind)
    )
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

    test "the table holds every entry of the word file" do
      assert Games.get_word_count() == length(WordList.entries())
    end

    test "all words are valid strings" do
      {:ok, words} = Games.get_all_words()

      assert length(words) > 200

      Enum.each(words, fn word ->
        assert is_binary(word.text)
        assert String.length(word.text) > 0
        assert String.length(word.text) <= 60
        assert Regex.match?(~r/\A[a-z' -]+\z/, word.text)
      end)
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

      # Each difficulty has single words and phrases
      assert length(easy) >= 60
      assert length(medium) >= 60
      assert length(hard) >= 60
    end
  end

  describe "selection by kind" do
    test "get_words_by_difficulty_and_kind returns words or phrases of every length" do
      for difficulty <- WordList.difficulties() do
        {:ok, words} = Games.get_words_by_difficulty_and_kind(difficulty, :word)
        assert length(words) == file_count(difficulty, :word)
        assert Enum.all?(words, &(&1.difficulty == difficulty and &1.word_count == 1))

        {:ok, phrases} = Games.get_words_by_difficulty_and_kind(difficulty, :phrase)
        assert length(phrases) == file_count(difficulty, :phrase)
        assert phrases != []
        assert Enum.all?(phrases, &(&1.difficulty == difficulty and &1.word_count in 2..4))
      end

      {:ok, hard} = Games.get_words_by_difficulty_and_kind(:hard, :phrase)
      assert hard |> Enum.map(& &1.word_count) |> Enum.uniq() |> Enum.sort() == [2, 3, 4]
    end

    test "an unknown kind is invalid" do
      for kind <- [:phrases, :words, 2, nil] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Games.get_words_by_difficulty_and_kind(:easy, kind)
      end
    end

    test "get_random_word returns the kind asked for, a word by default" do
      for _ <- 1..30 do
        {:ok, word} = Games.get_random_word()
        assert AnswerKind.of(word) == :word

        {:ok, word} = Games.get_random_word(kind: :word)
        assert AnswerKind.of(word) == :word

        {:ok, phrase} = Games.get_random_word(kind: :phrase)
        assert AnswerKind.of(phrase) == :phrase
      end
    end

    # No four-word phrase is easy: phrases are one pool, never picked by
    # their exact word count, so every difficulty yields one.
    test "every difficulty has phrases to pick" do
      for difficulty <- WordList.difficulties(), _ <- 1..5 do
        {:ok, phrase} = Games.get_random_word(kind: :phrase, difficulty: difficulty)
        assert AnswerKind.of(phrase) == :phrase
      end
    end
  end

  describe "smart word selection" do
    test "get_random_word with difficulty option returns word of that difficulty" do
      {:ok, word} = Games.get_random_word(difficulty: :easy, kind: :word)
      {:ok, easy_words} = Games.get_words_by_difficulty_and_kind(:easy, :word)
      easy_texts = Enum.map(easy_words, & &1.text)
      assert word in easy_texts
    end

    test "get_random_word excludes specified words" do
      # Get all 1-word easy words and exclude all but one
      {:ok, easy_words} = Games.get_words_by_difficulty_and_kind(:easy, :word)
      all_but_last = easy_words |> Enum.map(& &1.text) |> Enum.drop(-1)

      {:ok, word} = Games.get_random_word(difficulty: :easy, kind: :word, exclude: all_but_last)
      refute word in all_but_last
    end

    test "get_random_word falls back when all words excluded" do
      # Excluding everything should still return a word (falls back to unfiltered)
      {:ok, word} =
        Games.get_random_word(
          difficulty: :easy,
          kind: :word,
          exclude: Enum.map(WordList.entries(), & &1.text)
        )

      assert is_binary(word)
    end
  end

  describe "sync_words/0" do
    defp table, do: Map.new(Games.get_all_words!(), &{&1.text, &1})

    test "fills an empty table with exactly the file's entries" do
      Enum.each(Games.get_all_words!(), &Ash.destroy!/1)

      entries = WordList.entries()
      assert Games.sync_words() == %{inserted: length(entries), updated: 0, deleted: 0}

      table = table()
      assert map_size(table) == length(entries)

      for entry <- entries do
        row = Map.fetch!(table, entry.text)
        assert {row.difficulty, row.theme} == {entry.difficulty, entry.theme}
        assert row.word_count == WordList.word_count(entry.text)
      end
    end

    test "inserts the entries the table lacks" do
      [first, second | _] = WordList.entries()
      Enum.each([first, second], &Ash.destroy!(table()[&1.text]))

      assert Games.sync_words() == %{inserted: 2, updated: 0, deleted: 0}
      assert Map.has_key?(table(), first.text) and Map.has_key?(table(), second.text)
    end

    test "updates the difficulty and theme of rows that differ from the file" do
      entry = hd(WordList.entries())
      other_difficulty = hd(WordList.difficulties() -- [entry.difficulty])
      row = table()[entry.text]

      Ash.update!(row, %{difficulty: other_difficulty, theme: :sports})

      assert Games.sync_words() == %{inserted: 0, updated: 1, deleted: 0}

      synced = table()[entry.text]
      assert synced.id == row.id
      assert {synced.difficulty, synced.theme} == {entry.difficulty, entry.theme}
    end

    test "deletes rows that are no longer in the file" do
      Games.create_word!(%{text: "test stale word", difficulty: :easy})
      Games.create_word!(%{text: "teststale", difficulty: :hard})

      assert Games.sync_words() == %{inserted: 0, updated: 0, deleted: 2}
      refute Map.has_key?(table(), "test stale word")
      assert Games.get_word_count() == length(WordList.entries())
    end

    test "a second run changes nothing" do
      ids = Map.new(table(), fn {text, row} -> {text, row.id} end)

      assert Games.sync_words() == %{inserted: 0, updated: 0, deleted: 0}
      assert Map.new(table(), fn {text, row} -> {text, row.id} end) == ids
    end

    test "priv/repo/seeds.exs runs it" do
      Enum.each(Games.get_all_words!(), &Ash.destroy!/1)

      first = ExUnit.CaptureIO.capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)
      assert first =~ "words: #{length(WordList.entries())} inserted, 0 updated, 0 deleted"

      second = ExUnit.CaptureIO.capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)
      assert second =~ "words: 0 inserted, 0 updated, 0 deleted"
    end
  end

  describe "the Word resource" do
    test "creating a word that already exists fails with a validation error" do
      text = hd(WordList.entries()).text

      for duplicate <- [text, String.upcase(text), "  #{text}  "] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 Games.create_word(%{text: duplicate, difficulty: :easy})

        assert Exception.message(error) =~ "has already been taken"
      end

      assert Games.get_word_count() == length(WordList.entries())
    end

    test "stores the text lowercase and derives word_count from it" do
      word = Games.create_word!(%{text: "TEST Big Wave", difficulty: :medium})
      assert {word.text, word.word_count} == {"test big wave", 3}

      word = Games.create_word!(%{text: "test-run", difficulty: :medium})
      assert word.word_count == 1
    end

    test "takes phrases of up to four words" do
      word = Games.create_word!(%{text: "test in the box", difficulty: :hard, theme: :objects})
      assert word.word_count == 4

      assert {:error, %Ash.Error.Invalid{}} =
               Games.create_word(%{text: "test in the big box", difficulty: :hard})
    end

    test "does not accept word_count as input" do
      assert {:error, %Ash.Error.Invalid{}} =
               Games.create_word(%{text: "test words", difficulty: :easy, word_count: 1})
    end

    test "theme is optional and one of the word file's themes" do
      assert Games.create_word!(%{text: "testa", difficulty: :easy}).theme == nil
      assert Games.create_word!(%{text: "testb", difficulty: :easy, theme: :food}).theme == :food

      assert {:error, %Ash.Error.Invalid{}} =
               Games.create_word(%{text: "testc", difficulty: :easy, theme: :pets})
    end
  end

  describe "builtin_words/2" do
    test "are the word file's entries of that kind (and difficulty)" do
      for kind <- [:word, :phrase], difficulty <- WordList.difficulties() do
        words = Word.builtin_words(kind, difficulty)
        assert length(words) == file_count(difficulty, kind)
        assert Enum.all?(words, &(AnswerKind.of(&1) == kind))
      end

      assert length(Word.builtin_words(:phrase)) ==
               Enum.sum(for d <- WordList.difficulties(), do: file_count(d, :phrase))

      assert length(Word.builtin_words(:word)) + length(Word.builtin_words(:phrase)) ==
               length(WordList.entries())
    end
  end
end
