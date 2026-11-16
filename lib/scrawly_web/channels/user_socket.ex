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
  # leaves `user_id` nil.
  #
  # The home page's board connects with a board token (ScrawlyWeb.BoardToken,
  # `board_token`): a valid one assigns the caller's actor key as `board_key`
  # (an account's id, or an anonymous visitor's "anon:" key), which only
  # DemoBoardChannel reads; it never makes the socket a user's for the game
  # channel. Without one the socket can watch the board but not draw. A
  # socket carrying both tokens keeps an account's board key only when it is
  # that user's.
  #
  # A connect always succeeds: the channels authorize what a socket may do.
  @impl true
  def connect(params, socket, _connect_info) do
    user_id = verified(params, "token", &ScrawlyWeb.SocketToken.verify/1)
    board_key = verified(params, "board_token", &ScrawlyWeb.BoardToken.verify/1)

    board_key =
      if user_id != nil and ScrawlyWeb.BoardToken.account_key?(board_key) and
           board_key != user_id,
         do: nil,
         else: board_key

    {:ok, socket |> assign(:user_id, user_id) |> assign(:board_key, board_key)}
  end

  defp verified(params, name, verify) do
    with token when is_binary(token) <- Map.get(params, name),
         {:ok, value} <- verify.(token) do
      value
    else
      _ -> nil
    end
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
  # A board socket of an account (its board key is the user's id) has the
  # user's id too, so revoking the user's tokens closes it as well.
  #
  # Returning `nil` makes this socket anonymous: account-less sockets must not
  # share one "user_socket:" id (a disconnect broadcast to it would hit them all).
  @impl true
  def id(%{assigns: %{user_id: user_id}}) when is_binary(user_id) and user_id != "",
    do: "user_socket:#{user_id}"

  def id(%{assigns: %{board_key: key}}) do
    if ScrawlyWeb.BoardToken.account_key?(key), do: "user_socket:#{key}", else: nil
  end

  def id(_socket), do: nil
end
