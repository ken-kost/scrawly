defmodule ScrawlyWeb.GameIntegrationTest do
  use ScrawlyWeb.ChannelCase, async: false

  alias Scrawly.Games
  alias Scrawly.Accounts.User

  setup do
    Scrawly.Games.Word.seed_words()

    {:ok, room} = Games.create_room(%{name: "Integration Test Room", max_players: 4})

    %{room: room}
  end

  defp create_user(email) do
    {:ok, user} =
      Ash.create(User, %{email: email}, authorize?: false)

    user
  end

  defp join_room_as_player(room, user) do
    {:ok, _player} =
      user
      |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
      |> Ash.update()

    user
  end

  defp setup_socket_with_user(user, room) do
    {:ok, _, socket} =
      ScrawlyWeb.UserSocket
      |> socket("user_id", %{user_id: user.id})
      |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room.code}")

    socket
  end

  describe "room and player joining" do
    test "players can join a room and connect to channel", %{room: room} do
      player1 = create_user("player1-#{System.unique_integer([:positive])}@test.com")

      join_room_as_player(room, player1)

      socket1 = setup_socket_with_user(player1, room)

      assert socket1.assigns.room_code == room.code
      assert socket1.assigns.user_id == player1.id
    end
  end

  describe "multi-player coordination" do
    test "multiple players can join same room", %{room: room} do
      players =
        for i <- 1..4 do
          user = create_user("player#{i}-#{System.unique_integer([:positive])}@test.com")
          join_room_as_player(room, user)
          user
        end

      # All players can connect to the channel
      sockets =
        Enum.map(players, fn player ->
          setup_socket_with_user(player, room)
        end)

      assert length(sockets) == 4
    end

    test "all players receive chat messages from any player", %{room: room} do
      player1 = create_user("chatplayer1-#{System.unique_integer([:positive])}@test.com")
      player2 = create_user("chatplayer2-#{System.unique_integer([:positive])}@test.com")

      join_room_as_player(room, player1)
      join_room_as_player(room, player2)

      socket1 = setup_socket_with_user(player1, room)
      _socket2 = setup_socket_with_user(player2, room)

      ref = push(socket1, "chat_message", %{"message" => "Hello from player 1!"})
      assert_reply ref, :ok, %{status: "message_sent"}

      assert_broadcast "chat_message", %{
        "message" => "Hello from player 1!",
        "username" => _username
      }
    end
  end

  describe "drawing synchronization" do
    test "drawing events are broadcast to all players in room", %{room: room} do
      player1 = create_user("drawer1-#{System.unique_integer([:positive])}@test.com")
      player2 = create_user("drawer2-#{System.unique_integer([:positive])}@test.com")

      join_room_as_player(room, player1)
      join_room_as_player(room, player2)

      player1_id = player1.id

      socket1 = setup_socket_with_user(player1, room)
      _socket2 = setup_socket_with_user(player2, room)

      ref = push(socket1, "drawing_start", %{"x" => 100, "y" => 200})
      assert_reply ref, :ok, %{status: "drawing_started"}

      assert_broadcast "drawing_start", %{
        "x" => 100,
        "y" => 200,
        "player_id" => ^player1_id
      }

      ref = push(socket1, "drawing_move", %{"x" => 110, "y" => 210})
      assert_reply ref, :ok, %{status: "drawing_moved"}

      assert_broadcast "drawing_move", %{
        "x" => 110,
        "y" => 210,
        "player_id" => ^player1_id
      }

      ref = push(socket1, "drawing_stop", %{})
      assert_reply ref, :ok, %{status: "drawing_stopped"}

      assert_broadcast "drawing_stop", %{
        "player_id" => ^player1_id
      }

      assert_broadcast "drawing_start", %{"player_id" => ^player1_id}
    end
  end

  describe "reconnection handling" do
    test "player can connect to room multiple times", %{room: room} do
      player = create_user("reconnect-#{System.unique_integer([:positive])}@test.com")
      join_room_as_player(room, player)

      player_id = player.id

      # First connection
      {:ok, _, socket1} =
        ScrawlyWeb.UserSocket
        |> socket("user_id", %{user_id: player.id})
        |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room.code}")

      assert socket1.assigns.room_code == room.code
      assert socket1.assigns.user_id == player_id
    end
  end

  describe "max capacity performance" do
    test "12 players (max capacity) can join room and channel" do
      {:ok, room} = Games.create_room(%{name: "Max Players Room", max_players: 12})

      players =
        for i <- 1..12 do
          user = create_user("maxplayer#{i}-#{System.unique_integer([:positive])}@test.com")
          join_room_as_player(room, user)
          user
        end

      sockets =
        Enum.map(players, fn player ->
          setup_socket_with_user(player, room)
        end)

      assert length(sockets) == 12

      Enum.each(sockets, fn socket ->
        ref = push(socket, "chat_message", %{"message" => "Max player test"})
        assert_reply ref, :ok, %{status: "message_sent"}
      end)

      {:ok, updated_room} = Ash.get(Scrawly.Games.Room, room.id, load: [:players])
      assert length(updated_room.players) == 12
    end
  end
end
