defmodule Scrawly.Games.Room.Changes.DropThemesWhenAi do
  @moduledoc """
  A room that plays its own theme (`word_source: :ai`) plays none of the
  built-in list's themes: its `themes` are cleared. AI rooms ignore them.

  The counterpart of `DropThemeWhenLocal`. It reads the `word_source` the
  update sets (`WordSource.given/1`), so it works the same in an atomic
  UPDATE. An update that leaves `word_source` out leaves `themes` as they
  are; the settings form always sends both
  (`ScrawlyWeb.RoomSettings.to_attrs/2`).
  """

  use Ash.Resource.Change

  alias Scrawly.Games.Room.Changes.WordSource

  @impl true
  def change(changeset, _opts, _context) do
    if WordSource.given(changeset) in [:ai, "ai"],
      do: Ash.Changeset.force_change_attribute(changeset, :themes, []),
      else: changeset
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
