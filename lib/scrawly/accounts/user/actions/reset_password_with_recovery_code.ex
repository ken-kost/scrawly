defmodule Scrawly.Accounts.User.Actions.ResetPasswordWithRecoveryCode do
  @moduledoc """
  Runs `:reset_password_with_recovery_code`. The code only sets a new password;
  the token it returns is minted for the new password, like a sign-in would.

  Order matters:

    1. throttle reservation (`Scrawly.Accounts.Throttle`, `:recovery_email`
       by the database-normalised email and, with `context: %{client_ip: ip}`,
       `:recovery_ip`). The attempt is counted before anything else, so
       parallel requests can't exceed the limit; over it, no bcrypt runs;
    2. user lookup through `:get_by_email`, locking the row (`FOR UPDATE`, in
       the action's transaction): a second reset with the same code waits for
       the first to commit and then sees the new code, so a code works once;
    3. exactly one bcrypt operation, whether or not there is a usable account;
    4. on failure: the reservation stays counted; one generic error;
    5. on success: `:apply_recovery_reset` (new password + new code), revoke
       every stored token, then mint a fresh one, then hand the reservation
       back and clear the email's bucket.

  Revocation is explicit and happens before minting: the `log_out_everywhere`
  add-on's password-change hook can't be relied on here (see the task notes).
  """

  use Ash.Resource.Actions.Implementation

  alias AshAuthentication.BcryptProvider
  alias Scrawly.Accounts.{RecoveryCode, Throttle, User}
  alias Scrawly.Accounts.Errors.RecoveryRejected

  @impl true
  def run(input, _opts, context) do
    email = Ash.ActionInput.get_argument(input, :email)
    email_key = Throttle.email_key(email)
    opts = Ash.Context.to_opts(context)

    buckets = [{:recovery_email, email_key}, {:recovery_ip, input.context[:client_ip]}]

    case Throttle.reserve(buckets) do
      {:ok, ticket} ->
        user = lookup_locked(email, opts)

        if code_matches?(user, Ash.ActionInput.get_argument(input, :recovery_code)) do
          with {:ok, user} <- reset(user, input, opts) do
            Throttle.release(ticket)
            Throttle.clear(:recovery_email, email_key)
            {:ok, user}
          end
        else
          {:error, RecoveryRejected.exception(reason: :incorrect)}
        end

      {:error, :throttled} ->
        {:error, RecoveryRejected.exception(reason: :throttled)}
    end
  end

  defp lookup_locked(email, opts) do
    User
    |> Ash.Query.for_read(:get_by_email, %{email: email}, opts)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, %User{} = user} -> user
      _ -> nil
    end
  end

  # Exactly one bcrypt operation on every path. `valid?/2` has no clause for a
  # nil hash, hence `simulate/0` for unknown emails, guests and accounts that
  # never set up a code.
  defp code_matches?(%User{is_guest: false, hashed_recovery_code: hash}, code)
       when is_binary(hash) and hash != "" do
    BcryptProvider.valid?(RecoveryCode.normalize(code), hash)
  end

  defp code_matches?(_user, _code), do: BcryptProvider.simulate()

  defp reset(user, input, opts) do
    params = %{
      password: Ash.ActionInput.get_argument(input, :password),
      password_confirmation: Ash.ActionInput.get_argument(input, :password_confirmation)
    }

    with {:ok, user} <-
           user
           |> Ash.Changeset.for_update(:apply_recovery_reset, params, opts)
           |> Ash.update(),
         :ok <- revoke_all_tokens(user, opts),
         {:ok, token, _claims} <-
           AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "user"}) do
      {:ok, Ash.Resource.put_metadata(user, :token, token)}
    else
      :error -> {:error, "could not issue a sign-in token"}
      {:error, error} -> {:error, error}
    end
  end

  defp revoke_all_tokens(user, opts) do
    strategy = AshAuthentication.Info.strategy!(User, :log_out_everywhere)
    AshAuthentication.Strategy.action(strategy, :log_out_everywhere, %{user: user}, opts)
  end
end
