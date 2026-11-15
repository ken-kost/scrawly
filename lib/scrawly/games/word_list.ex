defmodule Scrawly.Games.WordList do
  @moduledoc """
  The drawing words. `priv/words/words.csv` is their only source: this module
  compiles it in, `Scrawly.Games.sync_words/0` makes the `words` table match
  it on every deploy, and `Scrawly.Games.Word.builtin_words/2` falls back to
  it when the table has nothing to offer.

  ## The file

  Plain CSV without quoting: the header, then one entry per line.

      text,difficulty,theme
      lighthouse,medium,places
      ice cream,easy,food

    * `text` - what the drawer draws and the others guess: lowercase letters,
      spaces, hyphens and apostrophes (never a comma), at most 30 characters,
      1 to 4 words (a phrase has 2 to 4), unique by
      `Scrawly.Games.Guess.key/1`. Its word count is derived (`word_count/1`).
    * `difficulty` - one of `difficulties/0`.
    * `theme` - one of `themes/0`. The format allows an empty theme (`nil`),
      but the lint requires one on every entry.

  A line without exactly three fields, or with an unknown difficulty or theme,
  fails compilation and names the line. `test/scrawly/games/word_list_test.exs`
  checks the rest: the text rules, duplicates, themes, and enough entries per
  group, difficulty and theme. `priv/words/README.md` holds the editorial
  rules: what makes a good entry or phrase, how to rate its difficulty and
  which theme it takes.
  """

  @type difficulty :: :easy | :medium | :hard
  @type theme ::
          :animals
          | :food
          | :objects
          | :nature
          | :places
          | :people
          | :actions
          | :sports
          | :transport
          | :fantasy
  @type entry :: %{text: String.t(), difficulty: difficulty, theme: theme | nil}

  @difficulties [:easy, :medium, :hard]
  @themes [
    :animals,
    :food,
    :objects,
    :nature,
    :places,
    :people,
    :actions,
    :sports,
    :transport,
    :fantasy
  ]

  @path Path.expand("../../../priv/words/words.csv", __DIR__)
  @external_resource @path

  # Parsed while this module compiles (its own functions don't exist yet, hence
  # the code in the module body), so a malformed file fails the build.
  [{header, _line} | rows] =
    @path
    |> File.read!()
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _number} -> line == "" end)

  if header != "text,difficulty,theme" do
    raise "priv/words/words.csv:1: the header must be text,difficulty,theme, got #{inspect(header)}"
  end

  parse_line = fn line, number ->
    location = "priv/words/words.csv:#{number}"

    value = fn field, allowed ->
      Enum.find(allowed, &(Atom.to_string(&1) == field)) ||
        raise "#{location}: #{inspect(field)} is none of #{Enum.join(allowed, ", ")}"
    end

    case String.split(line, ",") do
      [text, difficulty, theme] ->
        %{
          text: text,
          difficulty: value.(difficulty, @difficulties),
          theme: if(theme != "", do: value.(theme, @themes))
        }

      _fields ->
        raise "#{location}: expected text,difficulty,theme, got #{inspect(line)}"
    end
  end

  @entries Enum.map(rows, fn {line, number} -> parse_line.(line, number) end)

  @doc "Every entry of the file, in file order."
  @spec entries() :: [entry]
  def entries, do: @entries

  @doc "The values of the `difficulty` column."
  @spec difficulties() :: [difficulty]
  def difficulties, do: @difficulties

  @doc "The values of the `theme` column (which may also be empty)."
  @spec themes() :: [theme]
  def themes, do: @themes

  @doc """
  The number of words in a text: `1` for "cat" and "t-shirt", `2` for
  "ice cream". The `words` table stores it as `word_count`.
  """
  @spec word_count(String.t()) :: non_neg_integer
  def word_count(text), do: text |> String.split() |> length()
end
