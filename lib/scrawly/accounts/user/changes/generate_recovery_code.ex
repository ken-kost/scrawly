defmodule Scrawly.Accounts.User.Changes.GenerateRecoveryCode do
  @moduledoc """
  Issues a new recovery code: stores only its bcrypt hash (and the time) and
  returns the plaintext once, as `user.__metadata__.recovery_code`.

  Hashing happens in a `before_action`, so the change is not atomic; update
  actions that use it need `require_atomic? false`. The plaintext lives only in
  this closure and the result metadata: never log it or put it in the session.
  """

  use Ash.Resource.Change

  alias AshAuthentication.BcryptProvider
  alias Scrawly.Accounts.RecoveryCode

  @impl true
  def change(changeset, _opts, _context) do
    code = RecoveryCode.generate()

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      case BcryptProvider.hash(RecoveryCode.normalize(code)) do
        {:ok, hash} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:hashed_recovery_code, hash)
          |> Ash.Changeset.force_change_attribute(:recovery_code_generated_at, DateTime.utc_now())

        :error ->
          Ash.Changeset.add_error(changeset, "could not issue a recovery code")
      end
    end)
    |> Ash.Changeset.after_action(fn _changeset, user ->
      {:ok, Ash.Resource.put_metadata(user, :recovery_code, code)}
    end)
  end
end
