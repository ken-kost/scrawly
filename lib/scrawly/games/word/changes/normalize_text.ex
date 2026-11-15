defmodule Scrawly.Games.Word.Changes.NormalizeText do
  @moduledoc """
  Stores a word's text lowercase, so the unique identity on `text` ignores
  case ("Cat" and "cat" are the same word), and sets `word_count` from it
  (`Scrawly.Games.WordList.word_count/1`). Callers never supply the count.
  """

  use Ash.Resource.Change

  alias Scrawly.Games.WordList

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :text) do
      text when is_binary(text) ->
        text = String.downcase(text)

        changeset
        |> Ash.Changeset.force_change_attribute(:text, text)
        |> Ash.Changeset.force_change_attribute(:word_count, WordList.word_count(text))

      _missing ->
        changeset
    end
  end
end
