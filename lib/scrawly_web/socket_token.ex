defmodule ScrawlyWeb.SocketToken do
  @moduledoc """
  The token a game page hands to `ScrawlyWeb.UserSocket` (the Phoenix socket
  that carries live stroke chunks). It replaces the session's sign-in JWT,
  which must never reach page JavaScript or Hologram state (state is rendered
  into the HTML and snapshotted by the browser for Back/Forward).

  It is a `Phoenix.Token` that is good only for opening that socket: it names
  the user and the `jti` of the session token it was minted from, and expires
  after #{div(30 * 60, 60)} minutes. `verify/1` also requires that session
  token to be still stored and unrevoked, so signing out, a password change or
  a recovery reset makes every socket token of that session useless, and the
  `"disconnect"` broadcast those send (`ScrawlyWeb.Auth.disconnect_sockets/1`)
  closes the sockets already connected.

  A page asks for a fresh one when its socket is refused or closed by the
  server (see GamePage's `:game_channel_refused`), and every room snapshot
  reply carries one.
  """

  alias AshAuthentication.Jwt
  alias Hologram.Server
  alias ScrawlyWeb.Auth

  @salt "game socket"
  @max_age 30 * 60

  @doc "Seconds a socket token stays valid."
  @spec max_age() :: pos_integer
  def max_age, do: @max_age

  @doc """
  A socket token for the session user, or `nil` without a valid session.
  Call it after the page middleware (or another session check) ran.
  """
  @spec mint(Server.t()) :: String.t() | nil
  def mint(%Server{} = server) do
    with user_id when is_binary(user_id) <- Auth.user_id(server),
         token when is_binary(token) <- Server.get_session(server, :user_token),
         {:ok, %{"jti" => jti}} when is_binary(jti) <- Jwt.peek(token) do
      Phoenix.Token.sign(ScrawlyWeb.Endpoint, @salt, %{"u" => user_id, "j" => jti})
    else
      _ -> nil
    end
  end

  @doc """
  The user a socket token stands for: `{:ok, user_id}` while the token is
  younger than `max_age/0` and its session token is still stored and
  unrevoked, else `:error`. One tokens lookup. Never raises.
  """
  @spec verify(term) :: {:ok, String.t()} | :error
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(ScrawlyWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{"u" => user_id, "j" => jti}} ->
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
end
