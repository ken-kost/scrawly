defmodule Scrawly.Games.WordListTest do
  @moduledoc """
  Lints priv/words/words.csv, the only word list (see `Scrawly.Games.WordList`
  for the format). A failure lists the offending entries.
  """

  use ExUnit.Case, async: true

  alias Scrawly.Games.{Guess, WordList}

  @path "priv/words/words.csv"

  defp texts, do: Enum.map(WordList.entries(), & &1.text)

  defp single_words, do: Enum.filter(WordList.entries(), &(WordList.word_count(&1.text) == 1))

  describe "priv/words/words.csv" do
    test "is the header and one line per entry, every field kept as written" do
      [header | lines] = @path |> File.read!() |> String.split("\n", trim: true)

      assert header == "text,difficulty,theme"

      assert lines ==
               Enum.map(WordList.entries(), &Enum.join([&1.text, &1.difficulty, &1.theme], ","))
    end

    # A guess scores when its `Guess.key/1` equals the word's, so two entries
    # with one key ("pop corn" and "popcorn") would be the same answer.
    test "has no two entries with the same guess key" do
      clashes =
        texts()
        |> Enum.group_by(&Guess.key/1)
        |> Enum.filter(fn {_key, texts} -> length(texts) > 1 end)
        |> Enum.map(fn {_key, texts} -> texts end)

      assert clashes == []
    end

    test "texts are lowercase letters, spaces, hyphens and apostrophes" do
      assert Enum.reject(texts(), &(&1 =~ ~r/\A[a-z' -]+\z/)) == []
    end

    test "texts are at most 30 characters" do
      assert Enum.filter(texts(), &(String.length(&1) > 30)) == []
    end

    test "texts have no leading, trailing or double spaces" do
      assert Enum.filter(texts(), &(&1 != String.trim(&1) or String.contains?(&1, "  "))) == []
    end

    # The `words` table's word_count allows 1 to 3 (`Scrawly.Games.Word`), so
    # a longer entry would make the deploy's sync fail.
    test "texts have 1 to 3 words" do
      assert Enum.reject(texts(), &(WordList.word_count(&1) in 1..3)) == []
    end

    test "difficulties and themes are valid" do
      for entry <- WordList.entries() do
        assert entry.difficulty in WordList.difficulties(), inspect(entry)
        assert entry.theme in [nil | WordList.themes()], inspect(entry)
      end
    end

    test "every single-word entry has a theme" do
      assert Enum.filter(single_words(), &is_nil(&1.theme)) == []
    end

    # priv/words/README.md: a longer single word earns its place only if it
    # is common. List such a word here.
    @common_long_words []

    test "single words have at most 12 letters" do
      long =
        for %{text: text} <- single_words(),
            text not in @common_long_words,
            String.length(String.replace(text, ~r/[^a-z]/, "")) > 12,
            do: text

      assert long == []
    end

    # The word-list review of 2026-11-15 (priv/words/README.md has the rules).
    @basics ~w(frog shark heart robot sword zebra ghost octopus elephant dolphin dragon clock)
    @obscure ~w(nib sac sap jab lad tab tow vat use rod oat rye koi den ivy urn keg)
    @look_alikes ~w(aspen birch cedar spruce willow maple elm quartz slate marble granite
                    copper silver bronze crystal sapphire ruby emerald amber obsidian amethyst
                    tourmaline turquoise daisy poppy tulip orchid violet jasmine lotus
                    chrysanthemum bougainvillea wisteria)
    @spelling_tests ~w(archipelago kaleidoscope amphitheater aqueduct colosseum constellation
                       eucalyptus gyroscope hemisphere labyrinth metronome peninsula periscope
                       silhouette)

    test "has the basics" do
      assert @basics -- Enum.map(single_words(), & &1.text) == []
    end

    test "has none of the obscure, look-alike or spelling-test words" do
      removed = @obscure ++ @look_alikes ++ @spelling_tests
      assert Enum.filter(single_words(), &(&1.text in removed)) == []
    end

    test "every group (single word or several, by difficulty) has at least 30 entries" do
      counts =
        Enum.frequencies_by(WordList.entries(), fn entry ->
          {WordList.word_count(entry.text) == 1, entry.difficulty}
        end)

      for single? <- [true, false], difficulty <- WordList.difficulties() do
        count = Map.get(counts, {single?, difficulty}, 0)
        group = "#{if single?, do: "single words", else: "several words"}, #{difficulty}"
        assert count >= 30, "#{group}: only #{count} entries"
      end
    end
  end

  describe "a malformed file" do
    # Compiles a copy of WordList over `csv`: the file is parsed at compile
    # time, so a bad line fails the build instead of reaching the database.
    defp compile_with(csv) do
      dir = Path.join(System.tmp_dir!(), "word_list_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "words.csv")
      File.write!(path, csv)

      source = File.read!("lib/scrawly/games/word_list.ex")
      module = "WordListFixture#{System.unique_integer([:positive])}"

      fixture =
        source
        |> String.replace("defmodule Scrawly.Games.WordList do", "defmodule #{module} do")
        |> String.replace(
          ~s|Path.expand("../../../priv/words/words.csv", __DIR__)|,
          inspect(path)
        )

      assert fixture =~ module and fixture =~ inspect(path), "WordList's source changed shape"
      Code.compile_string(fixture)
    end

    test "with an unknown difficulty fails compilation, naming the line" do
      assert_raise RuntimeError, ~r/words\.csv:3: "extreme" is none of easy, medium, hard/, fn ->
        compile_with("text,difficulty,theme\ncat,easy,\ndog,extreme,\n")
      end
    end

    test "with an unknown theme fails compilation, naming the line" do
      assert_raise RuntimeError, ~r/words\.csv:2: "pets" is none of animals, food/, fn ->
        compile_with("text,difficulty,theme\ncat,easy,pets\n")
      end
    end

    test "with a line that isn't three fields fails compilation, naming the line" do
      assert_raise RuntimeError, ~r/words\.csv:2: expected text,difficulty,theme/, fn ->
        compile_with("text,difficulty,theme\ncat,easy\n")
      end

      assert_raise RuntimeError, ~r/words\.csv:2: expected text,difficulty,theme/, fn ->
        compile_with("text,difficulty,theme\ncat, dog,easy,\n")
      end
    end

    test "without the header fails compilation" do
      assert_raise RuntimeError, ~r/words\.csv:1: the header must be text,difficulty,theme/, fn ->
        compile_with("cat,easy,\n")
      end
    end

    test "that is well formed compiles into entries" do
      [{module, _bytecode}] = compile_with("text,difficulty,theme\r\ncat,easy,animals\r\n\r\n")

      assert module.entries() == [%{text: "cat", difficulty: :easy, theme: :animals}]
    end
  end
end
