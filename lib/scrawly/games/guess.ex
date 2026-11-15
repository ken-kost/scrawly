defmodule Scrawly.Games.Guess do
  @moduledoc """
  Server-side guess matching. Guesses are only ever checked here, inside the
  room process, never in the browser.

  Two texts are "the same word" when they have the same `key/1`: case,
  accents, spacing, hyphens, apostrophes and other punctuation don't matter.
  """

  @doc """
  The comparison key of `text`: `normalize/1`, then every space removed.

  Two texts have the same key exactly when they differ only in case, accents,
  spacing, hyphens, apostrophes or other punctuation:

      iex> Scrawly.Games.Guess.key("Ice-Cream!")
      "icecream"
      iex> Scrawly.Games.Guess.key("  ice  cream ")
      "icecream"
      iex> Scrawly.Games.Guess.key("Jack-o'-lantern")
      "jackolantern"
      iex> Scrawly.Games.Guess.key("Café")
      "cafe"

  Nothing else is forgiven: words are neither dropped ("jack in box" keeps
  its own key) nor corrected (typos keep theirs).

  A text with no letter or digit, or invalid UTF-8, has the key `""`. Treat
  it as "no word": `matches?/2` and `contains_word?/2` never match it.

  Use the key wherever two words, answers or guesses are compared as the same
  word: guess scoring, chat suppression, deduplicating a list of answers, or
  measuring how far a guess is from the answer.
  """
  @spec key(String.t()) :: String.t()
  def key(text) when is_binary(text), do: text |> words() |> Enum.join()

  @doc """
  True when `guess` and `word` have the same non-empty `key/1`, so a guess
  that differs only in case, accents, spacing, hyphens, apostrophes or other
  punctuation scores like the exact word: "ICE-CREAM!" and "icecream" match
  "ice cream", "pop corn" matches "popcorn", "cafe" matches "café".

  A missing word ("jack in box" for "jack in the box"), extra words ("it is
  ice cream") or a typo never match. A nil or empty guess or word never
  matches.
  """
  @spec matches?(term, term) :: boolean
  def matches?(guess, word) when is_binary(guess) and is_binary(word) do
    guess = key(guess)
    guess != "" and guess == key(word)
  end

  def matches?(_guess, _word), do: false

  @doc """
  True when some run of consecutive words of `text` (the words of its
  `normalize/1` form), joined together, has the same `key/1` as `word`.

  So the same variants `matches?/2` forgives are found inside a longer line:
  for "ice cream", "is it icecream", "ice-cream?", "ICE  CREAM!!" and
  "i c e cream" all contain it, and "a pop corn bag" contains "popcorn".
  The run must start and end on word boundaries, so a word inside another
  word doesn't count: "what" does not contain "hat", and "icecreams" does not
  contain "ice cream". Anything `matches?/2` accepts is contained. A nil or
  empty text or word never contains.

  Cost: from each word of the text, the walk goes on only while the words
  spell a prefix of the key, so a line of `n` words takes at most
  `n * byte_size(key)` prefix comparisons, and no joined string is built.

  The room process uses it to keep such lines off the chat while the word is
  being drawn (`RoomServer.submit_message/3`).
  """
  @spec contains_word?(term, term) :: boolean
  def contains_word?(text, word) when is_binary(text) and is_binary(word) do
    case key(word) do
      "" -> false
      key -> text |> words() |> any_run_spells?(key)
    end
  end

  def contains_word?(_text, _word), do: false

  @doc """
  Lowercase, accents stripped (canonical decomposition minus combining
  marks), every run of characters that are neither letters nor digits
  (punctuation, whitespace, symbols) turned into one space, trimmed.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text), do: text |> words() |> Enum.join(" ")

  # The words of `normalize/1`: lowercase, accents stripped, split on every
  # run of characters that are neither letters nor digits. Never contains an
  # empty word; invalid UTF-8 has none.
  defp words(text) do
    case :unicode.characters_to_nfd_binary(text) do
      decomposed when is_binary(decomposed) ->
        decomposed
        |> String.replace(~r/\p{Mn}+/u, "")
        |> String.downcase()
        |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

      _invalid ->
        []
    end
  end

  # True when the words starting at some position, joined, equal `key`.
  defp any_run_spells?([], _key), do: false

  defp any_run_spells?([_ | later] = words, key),
    do: spells?(words, key) or any_run_spells?(later, key)

  # Consumes `key` word by word while each word is a prefix of what is left;
  # true once nothing is left. Words are never empty, so every step eats at
  # least one byte of the key.
  defp spells?(_words, ""), do: true
  defp spells?([], _rest), do: false

  defp spells?([word | later], rest) do
    size = byte_size(word)

    case rest do
      <<^word::binary-size(size), left::binary>> -> spells?(later, left)
      _ -> false
    end
  end
end
