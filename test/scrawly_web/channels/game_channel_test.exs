defmodule ScrawlyWeb.GameChannelTest do
  use ScrawlyWeb.ChannelCase, async: false

  setup do
    # Create a user for testing
    {:ok, user} =
      Ash.create(
        Scrawly.Accounts.User,
        %{
          email: "test-#{System.unique_integer([:positive])}@example.com"
        },
        authorize?: false
      )

    # Create a room for testing
    {:ok, room} =
      Scrawly.Games.create_room(%{max_players: 4, name: "Test Room", creator_id: user.id})

    # Join the room as a player
    {:ok, player} =
      Ash.update(
        user,
        %{
          current_room_id: room.id,
          username: "TestPlayer"
        },
        action: :join_room
      )

    %{room: room, user: player}
  end

  describe "join" do
    test "joins game channel with valid room code and authenticated user", %{
      room: room,
      user: user
    } do
      # This should fail until we implement the channel
      {:ok, _, socket} =
        ScrawlyWeb.UserSocket
        |> socket("user_id", %{user_id: user.id})
        |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room.code}")

      assert socket.assigns.room_code == room.code
      assert socket.assigns.user_id == user.id
    end

    test "rejects join with invalid room code", %{user: user} do
      # This should fail until we implement the channel
      assert {:error, %{reason: "invalid_room"}} =
               ScrawlyWeb.UserSocket
               |> socket("user_id", %{user_id: user.id})
               |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:INVALID")
    end

    test "rejects join without authentication", %{room: room} do
      # This should fail with unauthorized when no user_id in socket
      assert {:error, %{reason: "unauthorized"}} =
               socket(ScrawlyWeb.UserSocket, "anonymous", %{})
               |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room.code}")
    end
  end

  describe "drawing events" do
    setup %{room: room, user: user} do
      # Ensure RoomServer is started for drawing persistence
      {:ok, _pid} = Scrawly.Games.RoomServer.ensure_started(room.id)

      {:ok, _, socket} =
        ScrawlyWeb.UserSocket
        |> socket("user_id", %{user_id: user.id})
        |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room.code}")

      %{socket: socket}
    end

    test "handles drawing_segment event", %{socket: socket} do
      ref = push(socket, "drawing_segment", %{"segment" => "M 10 20 L 30 40"})
      assert_reply ref, :ok, %{status: "segment_received"}

      assert_broadcast "drawing_segment", %{"segment" => "M 10 20 L 30 40"}
    end

    test "handles drawing_clear event", %{socket: socket} do
      ref = push(socket, "drawing_clear", %{})
      assert_reply ref, :ok, %{status: "drawing_cleared"}

      assert_broadcast "drawing_clear", %{}
    end

    test "handles get_drawing_path event", %{socket: socket, room: room} do
      Scrawly.Games.RoomServer.append_drawing(room.id, "M 5 5 L 10 10")

      ref = push(socket, "get_drawing_path", %{})
      assert_reply ref, :ok, %{path: path}
      assert path =~ "M 5 5 L 10 10"
    end
  end

  describe "chat events" do
    setup %{room: room, user: user} do
      {:ok, _, socket} =
        ScrawlyWeb.UserSocket
        |> socket("user_id", %{user_id: user.id})
        |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room.code}")

      %{socket: socket}
    end

    test "handles chat_message event", %{socket: socket, user: user} do
      ref = push(socket, "chat_message", %{"message" => "Hello everyone!"})
      assert_reply ref, :ok, %{status: "message_sent"}

      # Should broadcast to all players in room
      expected_username = user.username

      assert_broadcast "chat_message", %{
        "message" => "Hello everyone!",
        "username" => ^expected_username,
        "timestamp" => _
      }
    end

    test "rejects empty chat messages", %{socket: socket} do
      ref = push(socket, "chat_message", %{"message" => ""})
      assert_reply ref, :error, %{reason: "empty_message"}
    end
  end

  describe "presence tracking" do
    test "tracks player presence on join", %{room: room, user: user} do
      {:ok, _, _socket} =
        ScrawlyWeb.UserSocket
        |> socket("user_id", %{user_id: user.id})
        |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room.code}")

      # Should receive presence state as a push message
      assert_push "presence_state", presence_state
      assert Map.has_key?(presence_state, to_string(user.id))

      # Should also receive presence diff broadcast
      assert_broadcast "presence_diff", %{joins: joins}
      assert Map.has_key?(joins, to_string(user.id))
    end
  end
end
