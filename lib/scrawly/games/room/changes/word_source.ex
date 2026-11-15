defmodule Scrawly.Games.Room.Changes.WordSource do
  @moduledoc """
  The `word_source` an update of a Room sets, for the changes that keep a
  room to one topic (`DropThemeWhenLocal`, `DropThemesWhenAi`).

  A change sees it with `Ash.Changeset.fetch_change/2`, except in the atomic
  UPDATE Ash builds for an update given a record (`Ash.update/3` and code
  interfaces called with the record): there the action's inputs are
  expressions (`changeset.atomics`), so it is read from the inputs
  themselves (`changeset.params`).
  """

  @doc """
  The `word_source` the update sets (`:local`, `:ai`, or what the input
  holds), or `nil` when it leaves `word_source` out.
  """
  @spec given(Ash.Changeset.t()) :: term
  def given(changeset) do
    case Ash.Changeset.fetch_change(changeset, :word_source) do
      {:ok, value} -> value
      :error -> input(changeset.params)
    end
  end

  defp input(params) when is_map(params),
    do: Map.get(params, :word_source, Map.get(params, "word_source"))

  defp input(_params), do: nil
end
