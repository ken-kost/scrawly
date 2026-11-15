defmodule ScrawlyWeb.PlayFeedback do
  @moduledoc """
  The game page's play feedback as text: the answer and its blanks as one
  block per word, the "3 words · 11 letters" label, the "you got it" and
  "is close" lines, round summary points and who draws next.

  Pure and client-safe: GamePage's template and actions run these in the
  browser on every render, so they use only functions Hologram's client
  runtime has (`String.split/2` with a plain pattern, `Integer.to_string/1`).
  """

  # The room's masks (Scrawly.Games.WordHints) put one space between two
  # characters, so the space between two words becomes three.
  @mask_word_gap "   "

  @doc """
  The words of a masked display (`WordHints.hint_for_stage/3`), each still
  in the mask's own form, so a page can keep every word on one line:

      iex> ScrawlyWeb.PlayFeedback.mask_blocks("_ _ _   _ _ _ _ _")
      ["_ _ _", "_ _ _ _ _"]
      iex> ScrawlyWeb.PlayFeedback.mask_blocks("_ - _ _ _ _ _")
      ["_ - _ _ _ _ _"]
      iex> ScrawlyWeb.PlayFeedback.mask_blocks("")
      []

  Hyphens and apostrophes stay inside their word.
  """
  @spec mask_blocks(term) :: [String.t()]
  def mask_blocks(display) when is_binary(display),
    do: display |> String.split(@mask_word_gap) |> Enum.reject(&(&1 == ""))

  def mask_blocks(_display), do: []

  @doc """
  The words of a plain answer:

      iex> ScrawlyWeb.PlayFeedback.word_blocks("CHICKEN CROSSING THE ROAD")
      ["CHICKEN", "CROSSING", "THE", "ROAD"]
      iex> ScrawlyWeb.PlayFeedback.word_blocks(nil)
      []
  """
  @spec word_blocks(term) :: [String.t()]
  def word_blocks(text) when is_binary(text),
    do: text |> String.split(" ") |> Enum.reject(&(&1 == ""))

  def word_blocks(_text), do: []

  @doc """
  What the blanks hold: the letters, and the words too for a phrase. The
  words are counted on the masked display, so they match the blocks shown.

      iex> ScrawlyWeb.PlayFeedback.word_label("_ _ _ _ _", 5)
      "5 letters"
      iex> ScrawlyWeb.PlayFeedback.word_label("_ _ _   _ _ _ _ _ _ _ _   _ _ _ _", 15)
      "3 words · 15 letters"
  """
  @spec word_label(term, term) :: String.t()
  def word_label(display, letters) do
    letters = count(if(is_integer(letters), do: letters, else: 0), "letter")

    case length(mask_blocks(display)) do
      words when words > 1 -> count(words, "word") <> " · " <> letters
      _one_or_none -> letters
    end
  end

  @doc """
  True once the page's user has guessed the word this round: the room lists
  them in `correct_guessers`, or their own guess's reply (`guess_points`)
  got there first.
  """
  @spec guessed?(term, term, term) :: boolean
  def guessed?(correct_guessers, user_id, guess_points) do
    is_integer(guess_points) or
      (is_binary(user_id) and is_list(correct_guessers) and user_id in correct_guessers)
  end

  @doc """
  The line a player who has guessed the word sees:

      iex> ScrawlyWeb.PlayFeedback.got_it(350)
      "you got it · +350"
      iex> ScrawlyWeb.PlayFeedback.got_it(nil)
      "you got it"
  """
  @spec got_it(term) :: String.t()
  def got_it(points) when is_integer(points) and points > 0,
    do: "you got it · +" <> Integer.to_string(points)

  def got_it(_points), do: "you got it"

  @doc """
  A private line for the sender of a near miss. Only their own text: never
  a letter of the answer the hints haven't shown.

      iex> ScrawlyWeb.PlayFeedback.close_notice("popcorm")
      "'popcorm' is close!"
  """
  @spec close_notice(String.t()) :: String.t()
  def close_notice(text) when is_binary(text), do: "'" <> text <> "' is close!"

  @doc """
  Points gained in a round, as the round summary shows them:

      iex> ScrawlyWeb.PlayFeedback.points_label(350)
      "+350"
      iex> ScrawlyWeb.PlayFeedback.points_label(0)
      "—"
  """
  @spec points_label(term) :: String.t()
  def points_label(points) when is_integer(points) and points > 0,
    do: "+" <> Integer.to_string(points)

  def points_label(_points), do: "—"

  @doc """
  Who draws after this round:

      iex> ScrawlyWeb.PlayFeedback.next_turn("ann")
      "next: ann draws"
      iex> ScrawlyWeb.PlayFeedback.next_turn(nil)
      "last round · final scores next"
  """
  @spec next_turn(term) :: String.t()
  def next_turn(name) when is_binary(name), do: "next: " <> name <> " draws"
  def next_turn(_none), do: "last round · final scores next"

  defp count(1, noun), do: "1 " <> noun
  defp count(n, noun), do: Integer.to_string(n) <> " " <> noun <> "s"
end
