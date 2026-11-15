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

  require Ash.Query
  require Logger

  import Hologram.Component, only: [put_action: 3]

  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource
  alias Hologram.Server
  alias Scrawly.Accounts
  alias Scrawly.Accounts.{Token, User}

  # How long a replaced session token keeps working (put_session_user/3).
  @retire_grace_seconds 60

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

    case Jwt.peek(token) do
      {:ok, %{"sub" => ^subject, "jti" => jti}} -> verify_session_jti(user_id, jti)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def verify_session_token(_user_id, _token), do: :error

  @doc """
  `verify_session_token/2` by the token's `jti`: `{:ok, user_id, row}` while a
  stored, unrevoked, unexpired `"user"` token with that jti belongs to
  `user_id`. Used for socket tokens (`ScrawlyWeb.SocketToken`), which carry
  only the jti. One lookup. Never raises.
  """
  @spec verify_session_jti(term, term) :: {:ok, String.t(), Token.t()} | :error
  def verify_session_jti(user_id, jti)
      when is_binary(user_id) and user_id != "" and is_binary(jti) and jti != "" do
    subject = AshAuthentication.user_to_subject(%User{id: user_id})

    case TokenResource.Actions.get_token(Token, %{"jti" => jti, "purpose" => "user"}) do
      {:ok, [%Token{subject: ^subject} = row]} -> {:ok, user_id, row}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def verify_session_jti(_user_id, _jti), do: :error

  @doc """
  Signs `user` in on this session: writes `"user_id"` and `"user_token"`,
  records the Hologram identity (`put_user_id/2`) and updates the stash, so the
  rest of the request sees the new user. Every identity writer that runs as a
  Hologram command goes through here.

  A session holds one sign-in token: the one it held before (an account
  switch, a renewal by `ScrawlyWeb.Middleware.LoadCurrentUser`, a fresh token
  after a password change) is retired: it stops working
  #{@retire_grace_seconds} seconds later, so a copy of the old cookie can't
  sign in again. Not at once: requests already in flight from the browser's
  other tabs still carry the old cookie, and a revoked one would make their
  responses delete the session keys, overwriting the new cookie.
  """
  @spec put_session_user(Server.t(), User.t(), String.t()) :: Server.t()
  def put_session_user(%Server{} = server, %User{id: id} = user, token) when is_binary(token) do
    case Server.get_session(server, :user_token) do
      previous when is_binary(previous) and previous != token -> retire_token(previous)
      _same_or_none -> :ok
    end

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
  Password sign-in for a Hologram command (AppLayout `:login`, HomePage
  `:sign_in`): the one place both go through. Runs `:sign_in_with_password`
  with the caller's IP (`ScrawlyWeb.ClientIp`), which the action's throttle
  counts per email and per IP, and on success signs the session in
  (`put_session_user/3`, which retires the session's previous token).

  `{:error, :throttled}` means too many recent attempts; `{:error, :invalid}`
  covers a wrong password, an unknown email and malformed input alike.
  """
  @spec sign_in(Server.t(), term, term) ::
          {:ok, User.t(), Server.t()} | {:error, :invalid | :throttled}
  def sign_in(%Server{} = server, email, password)
      when is_binary(email) and is_binary(password) do
    case Accounts.sign_in_with_password(email, password,
           context: %{client_ip: ScrawlyWeb.ClientIp.from_server(server)}
         ) do
      {:ok, %User{} = user} ->
        {:ok, user, put_session_user(server, user, user.__metadata__.token)}

      {:error, error} ->
        if throttled?(error), do: {:error, :throttled}, else: {:error, :invalid}
    end
  end

  def sign_in(%Server{}, _email, _password), do: {:error, :invalid}

  defp throttled?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &throttled?/1)
  defp throttled?(%Scrawly.Accounts.Errors.SignInThrottled{}), do: true
  defp throttled?(_error), do: false

  @doc """
  Signs this session out (the header's "sign out", AppLayout `:sign_out`):
  revokes its sign-in token, tells the user's sockets to reconnect, deletes
  every application session key (as `Plug.Conn.clear_session/1` did for the
  old `GET /sign-out`; Hologram's own session id stays) and clears Hologram's
  identity.
  """
  @spec sign_out(Server.t()) :: Server.t()
  def sign_out(%Server{} = server) do
    user_id = Server.get_session(server, :user_id)

    case Server.get_session(server, :user_token) do
      token when is_binary(token) -> revoke_token(token)
      _ -> :ok
    end

    if is_binary(user_id) and user_id != "", do: disconnect_sockets(user_id)

    server.session
    |> Map.keys()
    |> Enum.reduce(server, &Server.delete_session(&2, &1))
    |> Server.delete_user_id()
    |> Server.put_stash(:current_user_id, nil)
    |> Server.put_stash(:current_user, nil)
  end

  @doc """
  Tells every `ScrawlyWeb.UserSocket` of the user to disconnect (their socket
  id is `"user_socket:<id>"`). Called whenever the user's tokens are revoked
  (sign-out, password change, recovery reset, guest upgrade). Phoenix doesn't
  retry a close the server asked for; the game page then asks for a fresh
  socket token (GamePage `:game_channel_refused`), which only a session that
  is still valid gets (`ScrawlyWeb.SocketToken`).
  """
  @spec disconnect_sockets(String.t()) :: :ok
  def disconnect_sockets(user_id) when is_binary(user_id) do
    ScrawlyWeb.Endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{})
    :ok
  end

  # Brings a stored sign-in token's expiry forward to the grace period (see
  # put_session_user/3). An unknown, malformed or soon-expiring one is left.
  defp retire_token(token) do
    with {:ok, %{"jti" => jti}} when is_binary(jti) <- Jwt.peek(token) do
      grace_until =
        DateTime.utc_now()
        |> DateTime.add(@retire_grace_seconds, :second)
        |> DateTime.truncate(:second)

      Token
      |> Ash.Query.filter(jti == ^jti and purpose == "user" and expires_at > ^grace_until)
      |> Ash.bulk_update(:retire, %{expires_at: grace_until},
        authorize?: false,
        strategy: [:atomic, :stream],
        return_errors?: true
      )
    end

    :ok
  rescue
    _ -> :error
  end

  # Revokes one sign-in token. A malformed or unknown token is ignored.
  defp revoke_token(token) do
    case TokenResource.Actions.revoke(Token, token) do
      :ok ->
        :ok

      {:error, _error} ->
        Logger.debug("could not revoke a session token")
        :error
    end
  rescue
    _ -> :error
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
    # A forged command name can be any term: bounded, and params never logged.
    Logger.warning(
      "command denied: #{inspect(command, limit: 5, printable_limit: 64)} (#{inspect(reason)}) " <>
        "for #{inspect(actor_key(server))}"
    )

    put_action(server, :command_denied, Keyword.merge(extra, command: command, reason: reason))
  end
end
