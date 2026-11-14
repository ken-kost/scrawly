defmodule ScrawlyWeb.UserSocketTest do
  use ScrawlyWeb.ChannelCase, async: true

  import Scrawly.RoomTestHelpers, only: [create_user: 0]

  alias ScrawlyWeb.UserSocket

  describe "id/1" do
    test "is nil for anonymous sockets, so they don't share one id" do
      for params <- [%{}, %{"token" => "not-a-jwt"}] do
        assert {:ok, socket} = connect(UserSocket, params)
        assert socket.assigns.user_id == nil
        assert UserSocket.id(socket) == nil
      end
    end

    test "is per user for a socket with a valid token" do
      user = create_user()
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "user"})

      assert {:ok, socket} = connect(UserSocket, %{"token" => token})
      assert UserSocket.id(socket) == "user_socket:#{user.id}"
    end
  end
end
