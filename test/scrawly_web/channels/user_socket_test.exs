defmodule ScrawlyWeb.UserSocketTest do
  use ScrawlyWeb.ChannelCase, async: true

  import Scrawly.RoomTestHelpers, only: [create_user: 0]
  import Scrawly.SessionTestHelpers, only: [signed_in_server: 2]

  alias ScrawlyWeb.{SocketToken, UserSocket}

  describe "id/1" do
    test "is nil for anonymous sockets, so they don't share one id" do
      for params <- [%{}, %{"token" => "not-a-token"}, %{"token" => 123}] do
        assert {:ok, socket} = connect(UserSocket, params)
        assert socket.assigns.user_id == nil
        assert UserSocket.id(socket) == nil
      end
    end

    test "is per user for a socket with a valid socket token" do
      user = create_user()
      token = SocketToken.mint(signed_in_server(user, load: :id_only))

      assert {:ok, socket} = connect(UserSocket, %{"token" => token})
      assert UserSocket.id(socket) == "user_socket:#{user.id}"
    end
  end
end
