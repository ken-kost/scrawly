defmodule Scrawly.Games.Room.Changes.DropThemeWhenLocal do
  @moduledoc """
  A room switched to the built-in list (`word_source: :local`) keeps no
  theme: its `prompt` is cleared, as a new built-in room has none.

  It reads the `word_source` the change sets, so it works the same in an
  atomic UPDATE (nothing is read from the stored row). An update that
  leaves `word_source` out leaves `prompt` as it is; the settings form
  always sends both (`ScrawlyWeb.RoomSettings.to_attrs/2`).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :word_source) do
      {:ok, :local} -> Ash.Changeset.force_change_attribute(changeset, :prompt, nil)
      _other -> changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
