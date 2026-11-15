defmodule ScrawlyWeb.UserSocket do
  use Phoenix.Socket

  # A Socket handler
  #
  # It's possible to control the websocket connection and
  # assign values that can be accessed by your channel topics.

  ## Channels

  channel "game:*", ScrawlyWeb.GameChannel
  channel "demo:board", ScrawlyWeb.DemoBoardChannel

  # The game page connects with a socket-only token (ScrawlyWeb.SocketToken),
  # never the session's sign-in JWT, which stays in the http-only session
  # cookie. A valid token (unexpired, and its session token still stored and
  # unrevoked: one lookup) assigns the user; anything else, including no token,
  # connects anonymously, which is enough for the public demo board. The
  # channels authorize what a socket may do.
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case ScrawlyWeb.SocketToken.verify(token) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      :error -> {:ok, assign(socket, :user_id, nil)}
    end
  end

  def connect(_params, socket, _connect_info) do
    {:ok, assign(socket, :user_id, nil)}
  end

  # Socket IDs are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     Elixir.ScrawlyWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # ScrawlyWeb.Auth.disconnect_sockets/1 does that whenever the user's tokens
  # are revoked (sign-out, password change, recovery reset, guest upgrade);
  # a new connect with a socket token of that session fails
  # SocketToken.verify/1.
  #
  # Returning `nil` makes this socket anonymous: account-less sockets must not
  # share one "user_socket:" id (a disconnect broadcast to it would hit them all).
  @impl true
  def id(%{assigns: %{user_id: user_id}}) when is_binary(user_id) and user_id != "",
    do: "user_socket:#{user_id}"

  def id(_socket), do: nil
end
