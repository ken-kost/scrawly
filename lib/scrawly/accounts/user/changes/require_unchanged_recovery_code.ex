defmodule Scrawly.Accounts.User.Changes.RequireUnchangedRecoveryCode do
  @moduledoc """
  Makes the update conditional on the stored recovery-code hash still being
  the one the record was loaded with (`WHERE hashed_recovery_code = <loaded>`).

  Two requests that loaded the same row can't both issue a code: the second
  UPDATE waits for the first one's row lock, then matches no row and fails
  with `Ash.Error.Changes.StaleRecord`, so a code shown to the user is always
  the stored one. A concurrent recovery reset (which locks the row) wins the
  same way.
  """

  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.data.hashed_recovery_code do
      nil -> Ash.Changeset.filter(changeset, Ash.Expr.expr(is_nil(hashed_recovery_code)))
      hash -> Ash.Changeset.filter(changeset, Ash.Expr.expr(hashed_recovery_code == ^hash))
    end
  end
end
