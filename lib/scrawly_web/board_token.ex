defmodule ScrawlyWeb.BoardToken do
  @moduledoc """
  The token the home page hands to `ScrawlyWeb.UserSocket` so the shared demo
  board (`ScrawlyWeb.DemoBoardChannel`) knows who draws: it names the
  caller's actor key (`ScrawlyWeb.Auth.actor_key/1`), which
  `Scrawly.Games.DemoBoardServer` stores with every stroke so a visitor can
  undo their own strokes and nobody else's. A socket without a valid one
  can watch the board, but every drawing event is refused.

  It is a `Phoenix.Token` with its own salt, good only for the board, and
  short-lived (#{div(10 * 60, 60)} minutes): it is needed only to (re)connect.
  It is never rendered or kept in page state: HomePage gets it in a
  command's reply (`:board_token` -> `:board_token_ready`) and hands it
  straight to demo_board.mjs, which keeps it in memory. A page asks for a
  fresh one whenever the board refuses it (an expired token after a
  reconnect, a closed socket: HomePage `:board_token_refused`).

  Revocation:

    * An account's key (a registered user or a guest account) is tied, as
      `ScrawlyWeb.SocketToken` is, to the `jti` of the session's sign-in
      token: `verify/1` requires that token to be still stored and
      unrevoked, so signing out, a password change, a recovery reset or a
      guest upgrade makes the board token useless for a new connect. The
      board socket's id is the user's (`"user_socket:<id>"`), so the
      `"disconnect"` broadcast those send (`ScrawlyWeb.Auth.disconnect_sockets/1`)
      closes a board socket already connected as well; the page then asks for
      a token, which names whoever the session is now.
    * An anonymous visitor's key (`"anon:"` plus a hash of the Hologram
      session id) has nothing on the server to revoke: no stored token, and
      the session cookie that the key is derived from is the visitor's only
      credential. So such a token is good until it expires, and only that
      short `max_age/0` bounds it. That is enough for what the key guards
      (undoing that visitor's own strokes on a public board anyone may
      clear), and the token lives only in that tab's memory. Signing in
      changes the key (the page reloads, dropping the old token) and the
      strokes drawn before stay the anonymous key's.
  """

  alias AshAuthentication.Jwt
  alias Hologram.Server
  alias ScrawlyWeb.Auth

  @salt "demo board socket"
  @max_age 10 * 60

  @doc "Seconds a board token stays valid."
  @spec max_age() :: pos_integer
  def max_age, do: @max_age

  @doc """
  A board token for the caller's actor key, or `nil` when there is none (no
  Hologram session id) or a signed-in session's token can't be read. Call it
  after the page middleware ran (a page's command).
  """
  @spec mint(Server.t()) :: String.t() | nil
  def mint(%Server{} = server) do
    case Auth.user_id(server) do
      nil ->
        case Auth.actor_key(server) do
          "anon:" <> _ = key -> sign(%{"k" => key})
          _none -> nil
        end

      user_id ->
        with token when is_binary(token) <- Server.get_session(server, :user_token),
             {:ok, %{"jti" => jti}} when is_binary(jti) <- Jwt.peek(token) do
          sign(%{"k" => user_id, "j" => jti})
        else
          _ -> nil
        end
    end
  end

  @doc """
  The actor key a board token stands for: `{:ok, key}` while it is younger
  than `max_age/0` and, for an account's key, its session token is still
  stored and unrevoked (one tokens lookup), else `:error`. Never raises.
  """
  @spec verify(term) :: {:ok, String.t()} | :error
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(ScrawlyWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{"k" => "anon:" <> _ = key} = claims} when map_size(claims) == 1 ->
        {:ok, key}

      {:ok, %{"k" => user_id, "j" => jti}} ->
        case Auth.verify_session_jti(user_id, jti) do
          {:ok, ^user_id, _row} -> {:ok, user_id}
          :error -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  def verify(_token), do: :error

  @doc "Whether `key` (from `verify/1`) is an account's, not an anonymous visitor's."
  @spec account_key?(term) :: boolean
  def account_key?("anon:" <> _), do: false
  def account_key?(key) when is_binary(key) and key != "", do: true
  def account_key?(_key), do: false

  defp sign(claims), do: Phoenix.Token.sign(ScrawlyWeb.Endpoint, @salt, claims)
end
