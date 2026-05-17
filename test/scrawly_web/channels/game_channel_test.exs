defmodule ScrawlyWeb.GameChannelTest do
  use ScrawlyWeb.ChannelCase, async: false

  setup do
    # Create a room for testing
    {:ok, room} = Scrawly.Games.create_room(%{name: "Test Room", max_players: 4})

    # Create a user for testing - username is auto-generated
    {:ok, user} =
      Ash.create(
        Scrawly.Accounts.User,
        %{
          email: "test-#{System.unique_integer([:positive])}@example.com"
        },
        authorize?: false
      )

    # Join the room as a player
    {:ok, player} =
      Ash.update(
        user,
        %{
          current_room_id: room.id
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
      {:ok, _, socket} =
        ScrawlyWeb.UserSocket
        |> socket("user_id", %{user_id: user.id})
        |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room.code}")

      %{socket: socket}
    end

    test "handles drawing_start event", %{socket: socket} do
      ref = push(socket, "drawing_start", %{"x" => 100, "y" => 150})
      assert_reply ref, :ok, %{status: "drawing_started"}

      # Should broadcast to other players
      assert_broadcast "drawing_start", %{"x" => 100, "y" => 150, "player_id" => _}
    end

    test "handles drawing_move event", %{socket: socket} do
      ref = push(socket, "drawing_move", %{"x" => 120, "y" => 160})
      assert_reply ref, :ok, %{status: "drawing_moved"}

      # Should broadcast to other players
      assert_broadcast "drawing_move", %{"x" => 120, "y" => 160, "player_id" => _}
    end

    test "handles drawing_stop event", %{socket: socket} do
      ref = push(socket, "drawing_stop", %{})
      assert_reply ref, :ok, %{status: "drawing_stopped"}

      # Should broadcast to other players
      assert_broadcast "drawing_stop", %{"player_id" => _}
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

    test "rate limits excessive chat messages", %{socket: socket} do
      # First 5 messages should succeed
      for _ <- 1..5 do
        ref = push(socket, "chat_message", %{"message" => "Test"})
        assert_reply ref, :ok, %{status: "message_sent"}
      end

      # 6th message should be rate limited
      ref = push(socket, "chat_message", %{"message" => "Too many"})
      assert_reply ref, :error, %{reason: "rate_limit_exceeded"}
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
