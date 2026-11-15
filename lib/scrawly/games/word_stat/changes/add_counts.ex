defmodule Scrawly.Games.WordStat.Changes.AddCounts do
  @moduledoc """
  Turns `WordStat :record`'s counts into increments. The accepted counts are
  the values a first sighting inserts; for an existing row (the upsert's ON
  CONFLICT branch) each counter becomes `counter + count` in the database,
  so concurrent records never lose one.
  """

  use Ash.Resource.Change

  import Ash.Expr, only: [expr: 1, ref: 1]

  alias Scrawly.Games.WordStat

  @impl true
  def change(changeset, _opts, _context) do
    Enum.reduce(WordStat.counters(), changeset, fn counter, changeset ->
      count = Ash.Changeset.get_attribute(changeset, counter) || 0
      Ash.Changeset.atomic_update(changeset, counter, expr(^ref(counter) + ^count))
    end)
  end
end
