defmodule Scrawly.Text do
  @moduledoc """
  Caps for text typed by users before it is stored or broadcast. Pure.

  A cap in characters (graphemes) alone doesn't bound size: one grapheme can
  be "a" followed by thousands of combining marks, megabytes in all. So text
  is cut to a number of characters AND a number of bytes, at a grapheme
  boundary (never inside a character), keeping the longest prefix within
  both.

  The Ash resources enforce the same byte caps on stored attributes with
  `Scrawly.Validations.MaxBytes`.
  """

  @doc """
  User input made ready to store: `""` for non-strings and invalid UTF-8,
  otherwise trimmed, cut by `truncate/3`, and trimmed again (a cut can end
  on a space). A line whose first character alone exceeds `max_bytes`
  becomes `""`.
  """
  @spec clean(term, non_neg_integer, non_neg_integer) :: String.t()
  def clean(text, max_chars, max_bytes) when is_binary(text) do
    if String.valid?(text) do
      text
      |> String.trim()
      |> truncate(max_chars, max_bytes)
      |> String.trim_trailing()
    else
      ""
    end
  end

  def clean(_text, _max_chars, _max_bytes), do: ""

  @doc """
  The longest prefix of `text` (valid UTF-8) of at most `max_chars`
  graphemes and `max_bytes` bytes. Reads no further than it keeps, plus one
  grapheme.
  """
  @spec truncate(String.t(), non_neg_integer, non_neg_integer) :: String.t()
  def truncate(text, max_chars, max_bytes) when is_binary(text) do
    binary_part(text, 0, prefix_bytes(text, max_chars, max_bytes, 0))
  end

  defp prefix_bytes(_rest, 0, _bytes_left, kept), do: kept

  defp prefix_bytes(rest, chars_left, bytes_left, kept) do
    case String.next_grapheme(rest) do
      {grapheme, rest} when byte_size(grapheme) <= bytes_left ->
        size = byte_size(grapheme)
        prefix_bytes(rest, chars_left - 1, bytes_left - size, kept + size)

      _end_or_too_big ->
        kept
    end
  end
end
