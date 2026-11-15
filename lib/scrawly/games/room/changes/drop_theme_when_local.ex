defmodule Scrawly.Games.Room.Changes.DropThemeWhenLocal do
  @moduledoc """
  A room switched to the built-in list (`word_source: :local`) keeps no
  theme: its `prompt` is cleared, as a new built-in room has none.

  It reads the `word_source` the update sets (`WordSource.given/1`), so it
  works the same in an atomic UPDATE (nothing is read from the stored row).
  An update that leaves `word_source` out leaves `prompt` as it is; the
  settings form always sends both (`ScrawlyWeb.RoomSettings.to_attrs/2`).
  """

  use Ash.Resource.Change

  alias Scrawly.Games.Room.Changes.WordSource

  @impl true
  def change(changeset, _opts, _context) do
    if WordSource.given(changeset) in [:local, "local"],
      do: Ash.Changeset.force_change_attribute(changeset, :prompt, nil),
      else: changeset
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
