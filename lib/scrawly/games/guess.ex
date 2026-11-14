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
    guess = normalize(guess)
    guess != "" and guess == normalize(word)
  end

  def matches?(_guess, _word), do: false

  defp normalize(text), do: text |> String.trim() |> String.downcase()
end
