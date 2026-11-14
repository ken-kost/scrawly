defmodule Scrawly.Accounts.User.Actions.ResetPasswordWithRecoveryCode do
  @moduledoc """
  Runs `:reset_password_with_recovery_code`. The code only sets a new password;
  the token it returns is minted for the new password, like a sign-in would.

  Order matters:

    1. throttle check (no bcrypt when over the limit);
    2. user lookup through `:get_by_email`;
    3. exactly one bcrypt operation, whether or not there is a usable account;
    4. on failure: record it and return one generic error;
    5. on success: `:apply_recovery_reset` (new password + new code), revoke
       every stored token, then mint a fresh one, then clear the throttle.

  Revocation is explicit and happens before minting: the `log_out_everywhere`
  add-on's password-change hook can't be relied on here (see the task notes).
  """

  use Ash.Resource.Actions.Implementation

  alias AshAuthentication.BcryptProvider
  alias Scrawly.Accounts.{RecoveryCode, RecoveryThrottle, User}
  alias Scrawly.Accounts.Errors.RecoveryRejected

  @impl true
  def run(input, _opts, context) do
    email = Ash.ActionInput.get_argument(input, :email)
    opts = Ash.Context.to_opts(context)

    if RecoveryThrottle.allowed?(email) do
      user = lookup(email, opts)

      if code_matches?(user, Ash.ActionInput.get_argument(input, :recovery_code)) do
        reset(user, input, email, opts)
      else
        RecoveryThrottle.record_failure(email)
        {:error, RecoveryRejected.exception(reason: :incorrect)}
      end
    else
      {:error, RecoveryRejected.exception(reason: :throttled)}
    end
  end

  defp lookup(email, opts) do
    User
    |> Ash.Query.for_read(:get_by_email, %{email: email}, opts)
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

  defp reset(user, input, email, opts) do
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
      RecoveryThrottle.clear(email)
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
