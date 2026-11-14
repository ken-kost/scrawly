defmodule ScrawlyWeb.Auth do
  @moduledoc """
  Server-side identity for Hologram middleware, inits and commands.

  Identity never comes from params. A session is signed in only while its
  `"user_token"` is a stored, unrevoked, unexpired sign-in token of its
  `"user_id"` (`verified_session/1`), so revoking tokens (sign-out,
  `log_out_everywhere`, a password change or a recovery reset) signs other
  browsers out on their next request.

  Every page runs `ScrawlyWeb.Middleware.LoadCurrentUser` (via
  `use ScrawlyWeb.Page`), which makes that check once per request and stashes
  `:current_user_id` (and, in its default mode, `:current_user`). `user_id/1`
  and `current_user/1` read the stash first and fall back to the session check
  only where no page middleware ran, i.e. AppLayout's commands.

  Server-only: call it from middleware, `init/3` and `command/3`, never from
  `action/3`.
  """

  require Logger

  import Hologram.Component, only: [put_action: 3]

  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource
  alias Hologram.Server
  alias Scrawly.Accounts
  alias Scrawly.Accounts.{Token, User}

  @doc """
  The session user's id, or `nil` when the visitor has no (valid) account.

  Reads the stash's `:current_user_id` when page middleware set it, otherwise
  runs `verified_session/1`.
  """
  @spec user_id(Server.t()) :: String.t() | nil
  def user_id(%Server{} = server) do
    case Server.get_stash(server, :current_user_id, :not_loaded) do
      :not_loaded ->
        case verified_session(server) do
          {:ok, id, _token} -> id
          :error -> nil
        end

      id ->
        id
    end
  end

  @doc """
  Loads the session user. Never raises.

  Reads the stash's `:current_user` when page middleware set it (a stashed
  `nil` means signed out), otherwise loads the user `user_id/1` names. A
  missing or invalid session, an unknown id and an id that isn't a valid UUID
  all count as `{:error, :unauthenticated}`.
  """
  @spec current_user(Server.t()) :: {:ok, User.t()} | {:error, :unauthenticated}
  def current_user(%Server{} = server) do
    case Server.get_stash(server, :current_user, :not_loaded) do
      %User{} = user -> {:ok, user}
      :not_loaded -> load_user(user_id(server))
      _nil -> {:error, :unauthenticated}
    end
  end

  @doc """
  Loads a user by id for the session. `{:error, :unauthenticated}` for nil,
  unknown and malformed ids. Never raises.
  """
  @spec load_user(term) :: {:ok, User.t()} | {:error, :unauthenticated}
  def load_user(id) when is_binary(id) do
    case Accounts.get_user_by_id(id) do
      {:ok, %User{} = user} -> {:ok, user}
      _nil_or_error -> {:error, :unauthenticated}
    end
  rescue
    _ -> {:error, :unauthenticated}
  end

  def load_user(_id), do: {:error, :unauthenticated}

  @doc """
  The one session check: `{:ok, user_id, token}` when the session's
  `"user_id"` and `"user_token"` are both binaries and the token is a stored,
  unrevoked, unexpired `"user"` token whose subject is that user. Never raises.
  """
  @spec verified_session(Server.t()) :: {:ok, String.t(), Token.t()} | :error
  def verified_session(%Server{} = server) do
    verify_session_token(
      Server.get_session(server, :user_id),
      Server.get_session(server, :user_token)
    )
  end

  @doc """
  `verified_session/1` for a raw `user_id` / `token` pair (the Phoenix
  controllers read their own `Plug.Conn` session).

  The claims are only peeked: the session cookie is signed by Plug.Session, and
  the stored token row is the authority. It costs one primary-key lookup.
  Revocation rewrites a row's purpose to `"revocation"`, so a revoked, expired
  or unknown token finds no row.
  """
  @spec verify_session_token(term, term) :: {:ok, String.t(), Token.t()} | :error
  def verify_session_token(user_id, token)
      when is_binary(user_id) and user_id != "" and is_binary(token) do
    subject = AshAuthentication.user_to_subject(%User{id: user_id})

    with {:ok, %{"sub" => ^subject, "jti" => jti}} when is_binary(jti) <- Jwt.peek(token),
         {:ok, [%Token{subject: ^subject} = row]} <-
           TokenResource.Actions.get_token(Token, %{"jti" => jti, "purpose" => "user"}) do
      {:ok, user_id, row}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def verify_session_token(_user_id, _token), do: :error

  @doc """
  Signs `user` in on this session: writes `"user_id"` and `"user_token"`,
  records the Hologram identity (`put_user_id/2`) and updates the stash, so the
  rest of the request sees the new user. Every identity writer that runs as a
  Hologram command goes through here.
  """
  @spec put_session_user(Server.t(), User.t(), String.t()) :: Server.t()
  def put_session_user(%Server{} = server, %User{id: id} = user, token) when is_binary(token) do
    server
    |> Server.put_session(:user_id, id)
    |> Server.put_session(:user_token, token)
    |> Server.put_user_id(id)
    |> Server.put_stash(:current_user_id, id)
    |> Server.put_stash(:current_user, user)
  end

  @doc """
  Mints a fresh sign-in token for `user` (stored, like a sign-in's) and puts
  the user on the session with it. `:error` when no token could be minted.
  """
  @spec put_fresh_token(Server.t(), User.t()) :: {:ok, Server.t()} | :error
  def put_fresh_token(%Server{} = server, %User{} = user) do
    case Jwt.token_for_user(user, %{"purpose" => "user"}) do
      {:ok, token, _claims} -> {:ok, put_session_user(server, user, token)}
      _error -> :error
    end
  end

  @doc """
  A stable key for the caller: the session user id when there is one, otherwise
  `"anon:"` plus the first 16 hex chars of the SHA-256 of the Hologram session id
  (hashed because watcher ids are broadcast to the whole room). `nil` when there
  is neither, e.g. in a bare `%Hologram.Server{}`.
  """
  @spec actor_key(Server.t()) :: term | nil
  def actor_key(%Server{} = server) do
    case user_id(server) do
      nil -> anon_key(server.session_id)
      id -> id
    end
  end

  defp anon_key(nil), do: nil

  defp anon_key(session_id) do
    digest =
      :crypto.hash(:sha256, to_string(session_id))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "anon:" <> digest
  end

  @doc """
  Rejects a command: logs a warning and replies with a `:command_denied` action
  whose params are `command`, `reason` and any `extra` entries (e.g. the
  stroke commands' `op_seq`). Changes no state and queues no broadcast.
  """
  @spec deny(Server.t(), atom, atom, keyword) :: Server.t()
  def deny(%Server{} = server, command, reason, extra \\ []) when is_atom(reason) do
    Logger.warning(
      "command denied: #{inspect(command)} (#{inspect(reason)}) for #{inspect(actor_key(server))}"
    )

    put_action(server, :command_denied, Keyword.merge(extra, command: command, reason: reason))
  end
end
