defmodule ScrawlyWeb.Middleware.LoadCurrentUser do
  @moduledoc """
  Page middleware (attached by `use ScrawlyWeb.Page`): checks the session once
  per request (`ScrawlyWeb.Auth.verified_session/1`) and stashes who is signed
  in, for `init/3`, the layout and the page's commands.

  Options: `load: :user` (default) or `load: :id_only`.

  Valid session:

    * stash `:current_user_id`;
    * `:user` mode loads the user (`:current_user`; a missing row counts as an
      invalid session) and renews the session token when it expires within
      7 days. `:id_only` loads nothing and leaves `:current_user` unset, so
      `ScrawlyWeb.Auth.current_user/1` loads it only if something asks;
    * syncs Hologram's identity (`put_user_id/2`).

  Invalid session (revoked, expired or unknown token, missing token, another
  user's token, deleted user): deletes the `"user_id"` and `"user_token"`
  session keys (theme keys and `"watch_mode"` stay), clears Hologram's identity
  and stashes `nil` for both keys. No session user: the same without session
  writes.

  It never sets a status, so it is safe on public pages.
  """

  use Hologram.Middleware

  alias ScrawlyWeb.Auth

  @renew_within_seconds 7 * 24 * 60 * 60

  @impl Hologram.Middleware
  def call(server, opts) do
    mode = Keyword.get(opts, :load, :user)

    unless mode in [:user, :id_only] do
      raise ArgumentError,
            "#{inspect(__MODULE__)} expects load: :user or load: :id_only, got: #{inspect(mode)}"
    end

    case Auth.verified_session(server) do
      {:ok, user_id, token} -> signed_in(server, user_id, token, mode)
      :error -> signed_out(server)
    end
  end

  @doc "Seconds before expiry from which a page load renews the session token."
  @spec renew_within_seconds() :: pos_integer
  def renew_within_seconds, do: @renew_within_seconds

  defp signed_in(server, user_id, _token, :id_only) do
    server
    |> put_stash(:current_user_id, user_id)
    |> sync_user_id(user_id)
  end

  defp signed_in(server, user_id, token, :user) do
    case Auth.load_user(user_id) do
      {:ok, user} ->
        server
        |> put_stash(:current_user_id, user_id)
        |> put_stash(:current_user, user)
        |> sync_user_id(user_id)
        |> maybe_renew(user, token)

      {:error, :unauthenticated} ->
        signed_out(server)
    end
  end

  defp signed_out(server) do
    server
    |> delete_session(:user_id)
    |> delete_session(:user_token)
    |> put_stash(:current_user_id, nil)
    |> put_stash(:current_user, nil)
    |> clear_user_id()
  end

  defp sync_user_id(%{user_id: user_id} = server, user_id), do: server
  defp sync_user_id(server, user_id), do: put_user_id(server, user_id)

  defp clear_user_id(%{user_id: nil} = server), do: server
  defp clear_user_id(server), do: delete_user_id(server)

  defp maybe_renew(server, user, %{expires_at: %DateTime{} = expires_at}) do
    if DateTime.diff(expires_at, DateTime.utc_now()) < @renew_within_seconds do
      case Auth.put_fresh_token(server, user) do
        {:ok, renewed} -> renewed
        :error -> server
      end
    else
      server
    end
  end

  defp maybe_renew(server, _user, _token), do: server
end
