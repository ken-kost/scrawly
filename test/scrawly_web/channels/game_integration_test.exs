defmodule ScrawlyWeb.GameIntegrationTest do
  use ScrawlyWeb.ChannelCase, async: false

  alias Scrawly.Accounts.User
  alias Scrawly.Games

  setup do
    Games.Word.seed_words()
    creator = create_user("creator-#{System.unique_integer([:positive])}@test.com")

    {:ok, room} =
      Games.create_room(%{name: "Integration Test Room", max_players: 8, creator_id: creator.id})

    %{room: room, creator: creator}
  end

  defp create_user(email) do
    {:ok, user} = Ash.create(User, %{email: email}, authorize?: false)
    user
  end

  defp join_channel(user_id, room_code) do
    ScrawlyWeb.UserSocket
    |> socket("socket_id", %{user_id: user_id})
    |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room_code}")
  end

  describe "game channel join (auth)" do
    test "an authenticated player can join", %{room: room} do
      player = create_user("player-#{System.unique_integer([:positive])}@test.com")

      assert {:ok, _reply, socket} = join_channel(player.id, room.code)
      assert socket.assigns.room_code == room.code
      assert socket.assigns.user_id == player.id
    end

    test "a guest (real user_id) can join too", %{room: room} do
      guest = Scrawly.Accounts.register_as_guest!()

      assert {:ok, _reply, socket} = join_channel(guest.id, room.code)
      assert socket.assigns.user_id == guest.id
    end

    test "the same player can connect multiple times", %{room: room} do
      player = create_user("rejoin-#{System.unique_integer([:positive])}@test.com")

      assert {:ok, _, _} = join_channel(player.id, room.code)
      assert {:ok, _, socket} = join_channel(player.id, room.code)
      assert socket.assigns.user_id == player.id
    end

    test "an unauthenticated socket is refused", %{room: room} do
      assert {:error, %{reason: "unauthorized"}} = join_channel(nil, room.code)
    end

    test "joining an unknown room is refused" do
      player = create_user("nobody-#{System.unique_integer([:positive])}@test.com")
      assert {:error, %{reason: "invalid_room"}} = join_channel(player.id, "NOPE99")
    end
  end
end
