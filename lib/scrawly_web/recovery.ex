defmodule ScrawlyWeb.Recovery do
  @moduledoc """
  Server halves of the recovery-code UI, shared by the components that own a
  `ScrawlyWeb.Components.RecoveryCodePanel`.

    * `reset_password/2` backs the `:reset_password` command of HomePage and
      AppLayout ("forgot password?"). It replies with `:show_recovery_code`
      (`code`, `username`, `avatar_id`, `avatar_color`) or
      `:recovery_reset_failed` (`message`).
    * `regenerate/2` backs ProfilePage's `:regenerate_recovery_code`. It replies
      with `:show_recovery_code` (`code`, `generated_label`) or
      `:recovery_code_failed` (`message`).

  The plaintext code travels only in that reply to the browser that asked. It
  is never written to the session and never logged. Params are read with
  `Map.get/3` so malformed input can't raise a FunctionClauseError (whose report
  would print the arguments).

  Server-only: call from `command/3`.
  """

  import Hologram.Component, only: [put_action: 3]

  alias Hologram.Server
  alias Scrawly.Accounts
  alias Scrawly.Accounts.Errors.RecoveryRejected

  @doc """
  Resets the password with an email + recovery code. On success the session
  is signed in with the token the reset minted (as `:sign_in` / `:login` do).
  The reset revoked every older token, so other browsers signed in to the
  account are signed out on their next request, and its sockets are told to
  reconnect. Attempts are throttled per email and per client IP
  (`Scrawly.Accounts.Throttle`).
  """
  @spec reset_password(map, Server.t()) :: Server.t()
  def reset_password(params, %Server{} = server) do
    result =
      Accounts.reset_password_with_recovery_code(
        string_param(params, :email),
        string_param(params, :recovery_code),
        string_param(params, :password),
        string_param(params, :password_confirmation),
        context: %{client_ip: ScrawlyWeb.ClientIp.from_server(server)}
      )

    case result do
      {:ok, user} ->
        ScrawlyWeb.Auth.disconnect_sockets(user.id)

        server
        |> ScrawlyWeb.Auth.put_session_user(user, user.__metadata__.token)
        |> Server.put_session(:dark_mode, user.dark_mode)
        |> Server.put_session(:accent_color, to_string(user.accent_color || :purple))
        |> put_action(:show_recovery_code,
          code: user.__metadata__.recovery_code,
          username: user.username,
          avatar_id: user.avatar_id,
          avatar_color: user.avatar_color
        )

      {:error, error} ->
        put_action(server, :recovery_reset_failed, message: reset_error_message(error))
    end
  end

  @doc """
  Issues a new code for the session user after checking `current_password`.
  The old code stops working.
  """
  @spec regenerate(map, Server.t()) :: Server.t()
  def regenerate(params, %Server{} = server) do
    with {:ok, user} <- ScrawlyWeb.Auth.current_user(server),
         {:ok, user} <-
           Accounts.regenerate_recovery_code(user, string_param(params, :current_password)) do
      put_action(server, :show_recovery_code,
        code: user.__metadata__.recovery_code,
        generated_label: generated_label(user.recovery_code_generated_at)
      )
    else
      {:error, :unauthenticated} ->
        put_action(server, :recovery_code_failed, message: "sign in again to manage your code")

      {:error, error} ->
        put_action(server, :recovery_code_failed, message: regenerate_error_message(error))
    end
  end

  @doc "How the profile page shows when the current code was issued."
  @spec generated_label(DateTime.t() | nil) :: String.t()
  def generated_label(nil), do: ""
  def generated_label(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @doc """
  The profile's recovery section state for `user`: `:guest`, `:active` or
  `:missing` (an account that predates codes).
  """
  @spec status(map) :: :guest | :active | :missing
  def status(%{is_guest: true}), do: :guest
  def status(%{hashed_recovery_code: hash}) when is_binary(hash), do: :active
  def status(_user), do: :missing

  defp string_param(params, key), do: ScrawlyWeb.CommandParams.string(params, key)

  defp reset_error_message(error) do
    errors = errors_of(error)

    cond do
      rejected = Enum.find(errors, &match?(%RecoveryRejected{}, &1)) ->
        RecoveryRejected.text(rejected)

      Enum.any?(errors, &match?(%Ash.Error.Changes.Required{}, &1)) ->
        "fill in your email, recovery code and new password"

      # A too-short password also fails the confirmation (the argument is
      # dropped), so length is checked first.
      on_field?(errors, :password) ->
        "use a new password of at least 8 characters"

      on_field?(errors, :password_confirmation) ->
        "the new passwords don't match"

      on_field?(errors, :recovery_code) ->
        RecoveryRejected.text(RecoveryRejected.exception([]))

      true ->
        "could not reset the password, try again"
    end
  end

  defp regenerate_error_message(%Ash.Error.Forbidden{}), do: "current password is incorrect"

  defp regenerate_error_message(error) do
    errors = errors_of(error)

    cond do
      # Another request changed the code meanwhile (RequireUnchangedRecoveryCode).
      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        "your code was just changed elsewhere. reload the page to see it."

      Enum.any?(errors, &match?(%Ash.Error.Changes.Required{}, &1)) ->
        "enter your current password"

      on_field?(errors, :is_guest) ->
        "register an account to get a recovery code"

      on_field?(errors, :hashed_password) ->
        "this account has no password to check"

      true ->
        "could not issue a new code, try again"
    end
  end

  defp errors_of(%{errors: errors}) when is_list(errors), do: errors
  defp errors_of(error), do: [error]

  defp on_field?(errors, field), do: Enum.any?(errors, &(Map.get(&1, :field) == field))
end
