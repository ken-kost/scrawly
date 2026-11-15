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

  defp phrases, do: Enum.filter(WordList.entries(), &(WordList.word_count(&1.text) > 1))

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

    # The `words` table's word_count allows 1 to 4 (`Scrawly.Games.Word`), so
    # a longer entry would make the deploy's sync fail.
    test "texts have 1 to 4 words" do
      assert Enum.reject(texts(), &(WordList.word_count(&1) in 1..4)) == []
    end

    test "difficulties and themes are valid" do
      for entry <- WordList.entries() do
        assert entry.difficulty in WordList.difficulties(), inspect(entry)
        assert entry.theme in [nil | WordList.themes()], inspect(entry)
      end
    end

    test "every entry has a theme" do
      assert Enum.filter(WordList.entries(), &is_nil(&1.theme)) == []
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

    test "each difficulty has at least 30 single words" do
      counts = Enum.frequencies_by(single_words(), & &1.difficulty)

      for difficulty <- WordList.difficulties() do
        count = Map.get(counts, difficulty, 0)
        assert count >= 30, "#{difficulty}: only #{count} single words"
      end
    end
  end

  # A phrase is an entry of two or more words (priv/words/README.md). A game
  # can be played with phrases only, so every difficulty and theme needs its
  # own supply.
  describe "the phrases" do
    test "have 2 to 4 words and at most 30 characters" do
      assert Enum.reject(phrases(), &(WordList.word_count(&1.text) in 2..4)) == []
      assert Enum.filter(phrases(), &(String.length(&1.text) > 30)) == []
    end

    test "each difficulty has at least 60 phrases" do
      counts = Enum.frequencies_by(phrases(), & &1.difficulty)

      for difficulty <- WordList.difficulties() do
        count = Map.get(counts, difficulty, 0)
        assert count >= 60, "#{difficulty}: only #{count} phrases"
      end
    end

    test "each theme has at least 15 phrases" do
      counts = Enum.frequencies_by(phrases(), & &1.theme)

      for theme <- WordList.themes() do
        count = Map.get(counts, theme, 0)
        assert count >= 15, "#{theme}: only #{count} phrases"
      end
    end

    # "pop corn" would be "popcorn" split in two: write the single word.
    test "none has a single word's guess key" do
      single_keys = MapSet.new(single_words(), &Guess.key(&1.text))

      assert Enum.filter(phrases(), &MapSet.member?(single_keys, Guess.key(&1.text))) == []
    end

    # The word-list review of 2026-11-15: invented pairs, abstract idioms and
    # phrases missing their articles.
    @rejected_phrases [
      "den lamp",
      "ark door",
      "gap fill",
      "urn lid",
      "wok pan",
      "yam pie",
      "jackal howl",
      "nectar sip",
      "ventricle pump",
      "tessellation tile",
      "quicksilver flow",
      "resonance hum",
      "give and take",
      "now and then",
      "abyss of time",
      "bane of existence",
      "zenith of power",
      "xyst of columns",
      "jack in box",
      "man on moon",
      "needle in haystack",
      "lord of rings",
      "once upon time"
    ]

    test "has none of the invented, abstract or article-less phrases" do
      assert Enum.filter(phrases(), &(&1.text in @rejected_phrases)) == []
    end

    test "no two share a guess key" do
      clashes =
        phrases()
        |> Enum.group_by(&Guess.key(&1.text), & &1.text)
        |> Map.values()
        |> Enum.filter(&match?([_, _ | _], &1))

      assert clashes == []
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
