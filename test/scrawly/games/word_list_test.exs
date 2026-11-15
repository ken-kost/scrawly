defmodule Scrawly.Games.WordListTest do
  @moduledoc """
  Lints priv/words/words.csv, the only word list (see `Scrawly.Games.WordList`
  for the format). A failure lists the offending entries.
  """

  use ExUnit.Case, async: true

  alias Scrawly.Games.WordList

  @path "priv/words/words.csv"

  defp texts, do: Enum.map(WordList.entries(), & &1.text)

  describe "priv/words/words.csv" do
    test "is the header and one line per entry, every field kept as written" do
      [header | lines] = @path |> File.read!() |> String.split("\n", trim: true)

      assert header == "text,difficulty,theme"

      assert lines ==
               Enum.map(WordList.entries(), &Enum.join([&1.text, &1.difficulty, &1.theme], ","))
    end

    test "has no two entries that differ only in case, spaces or hyphens" do
      clashes =
        texts()
        |> Enum.group_by(&(&1 |> String.downcase() |> String.replace([" ", "-"], "")))
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
