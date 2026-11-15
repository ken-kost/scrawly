defmodule Scrawly.Accounts.User.Preparations.ThrottleSignIn do
  @moduledoc """
  Throttles `:sign_in_with_password` (`Scrawly.Accounts.Throttle`): every
  attempt is counted per email and, when the caller passes
  `context: %{client_ip: ip}`, per client IP, before the user lookup and the
  bcrypt check run. Over a limit the action fails with
  `Scrawly.Accounts.Errors.SignInThrottled` and no bcrypt runs.

  A successful sign-in hands its slots back, so only failed (and in-flight)
  attempts fill a bucket. Declare it after `SignInPreparation`: read
  after-action hooks run in order (`read_action_after_action_hooks_in_order?`),
  and SignInPreparation's hook fails the action on a wrong password before the
  release runs.
  """

  use Ash.Resource.Preparation

  alias Scrawly.Accounts.Errors.SignInThrottled
  alias Scrawly.Accounts.Throttle

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.before_action(&reserve/1)
    |> Ash.Query.after_action(fn query, results ->
      case query.context[:sign_in_throttle_ticket] do
        nil -> :ok
        ticket -> Throttle.release(ticket)
      end

      {:ok, results}
    end)
  end

  defp reserve(query) do
    email_key = query |> Ash.Query.get_argument(:email) |> Throttle.email_key()
    client_ip = query.context[:client_ip]

    case Throttle.reserve([{:sign_in_email, email_key}, {:sign_in_ip, client_ip}]) do
      {:ok, ticket} -> Ash.Query.set_context(query, %{sign_in_throttle_ticket: ticket})
      {:error, :throttled} -> Ash.Query.add_error(query, SignInThrottled.exception([]))
    end
  end
end
