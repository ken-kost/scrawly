defmodule Scrawly.Games.Guess do
  @moduledoc """
  Server-side guess matching. Guesses are only ever checked here, inside the
  room process, never in the browser.
  """

  @doc """
  True when `guess` equals `word` after trimming and downcasing both.
  A nil or empty guess or word never matches.
  """
  @spec matches?(term, term) :: boolean
  def matches?(guess, word) when is_binary(guess) and is_binary(word) do
    guess = trim_down(guess)
    guess != "" and guess == trim_down(word)
  end

  def matches?(_guess, _word), do: false

  @doc """
  True when `text` contains `word` as a whole word (or, for a multi-word
  word, as the same run of words), once both are `normalize/1`d: case,
  accents, punctuation and whitespace don't matter, so "Zzyzx!" and "lol it
  is ZZYZX." contain "zzyzx", and "a hot-dog" contains "hot dog". A word
  inside another word doesn't count ("what" does not contain "hat"), and no
  other fuzziness is applied. A nil or empty text or word never contains.

  The room process uses it to keep such lines off the chat while the word is
  being drawn (`RoomServer.submit_message/3`).
  """
  @spec contains_word?(term, term) :: boolean
  def contains_word?(text, word) when is_binary(text) and is_binary(word) do
    case normalize(word) do
      "" -> false
      word -> String.contains?(" " <> normalize(text) <> " ", " " <> word <> " ")
    end
  end

  def contains_word?(_text, _word), do: false

  @doc """
  Lowercase, accents stripped (canonical decomposition minus combining
  marks), every run of characters that are neither letters nor digits
  (punctuation, whitespace, symbols) turned into one space, trimmed.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    case :unicode.characters_to_nfd_binary(text) do
      decomposed when is_binary(decomposed) ->
        decomposed
        |> String.replace(~r/\p{Mn}+/u, "")
        |> String.downcase()
        |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
        |> String.trim()

      _invalid ->
        ""
    end
  end

  defp trim_down(text), do: text |> String.trim() |> String.downcase()
end
