defmodule ScrawlyWeb.GameChannelDrawingTest do
  use ScrawlyWeb.ChannelCase

  alias ScrawlyWeb.GameChannel
  alias Scrawly.Accounts
  alias Scrawly.Games
  alias Scrawly.Games.RoomServer

  setup do
    {:ok, user} =
      Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "test-#{System.unique_integer([:positive])}@example.com"
      })
      |> Ash.create(authorize?: false)

    {:ok, room} = Games.create_room(%{name: "Test Room", max_players: 8, creator_id: user.id})
    {:ok, _pid} = RoomServer.ensure_started(room.id)
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    {:ok, socket} = connect(ScrawlyWeb.UserSocket, %{"token" => token})

    %{socket: socket, user: user, room: room}
  end

  describe "drawing_stroke (new format)" do
    test "broadcasts stroke with color and width", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref =
        push(socket, "drawing_stroke", %{
          "segment" => "M 10 20 L 30 40",
          "color" => "#EF4444",
          "width" => 5
        })

      assert_reply ref, :ok, %{status: "stroke_received"}

      assert_broadcast "drawing_stroke", %{
        "path" => "M 10 20 L 30 40",
        "color" => "#EF4444",
        "width" => 5
      }

      {:ok, state} = RoomServer.get_state(room.id)
      assert length(state.drawing_strokes) == 1
      [stroke] = state.drawing_strokes
      assert stroke.path == "M 10 20 L 30 40"
      assert stroke.color == "#EF4444"
      assert stroke.width == 5
    end

    test "defaults color and width when not provided", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_stroke", %{"segment" => "M 10 20"})
      assert_reply ref, :ok, %{status: "stroke_received"}

      {:ok, state} = RoomServer.get_state(room.id)
      [stroke] = state.drawing_strokes
      assert stroke.color == "#000000"
      assert stroke.width == 2
    end

    test "rejects empty strokes", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_stroke", %{"segment" => ""})
      assert_reply ref, :error, %{reason: "empty_segment"}
    end
  end

  describe "drawing_segment (legacy backward compat)" do
    test "converts to stroke with default color/width", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_segment", %{"segment" => "M 10 20 L 30 40"})
      assert_reply ref, :ok, %{status: "segment_received"}

      # Broadcasts as new stroke format
      assert_broadcast "drawing_stroke", %{
        "path" => "M 10 20 L 30 40",
        "color" => "#000000",
        "width" => 2
      }

      {:ok, state} = RoomServer.get_state(room.id)
      assert length(state.drawing_strokes) == 1
      [stroke] = state.drawing_strokes
      assert stroke.path == "M 10 20 L 30 40"
      assert stroke.color == "#000000"
    end
  end

    test "rejects empty segments", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_segment", %{"segment" => ""})
      assert_reply ref, :error, %{reason: "empty_segment"}
    end
  end

  describe "drawing_clear" do
    test "broadcasts clear and resets strokes", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      # Add a stroke first
      push(socket, "drawing_stroke", %{"segment" => "M 10 20", "color" => "#000000", "width" => 2})

      Process.sleep(50)

      ref = push(socket, "drawing_clear", %{})
      assert_reply ref, :ok, %{status: "drawing_cleared"}
      assert_broadcast "drawing_clear", %{}

      {:ok, state} = RoomServer.get_state(room.id)
      assert state.drawing_strokes == []
    end
  end

  describe "drawing_undo" do
    test "removes last stroke and broadcasts updated strokes", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      # Add two strokes
      push(socket, "drawing_stroke", %{"segment" => "M 10 20", "color" => "#000000", "width" => 2})

      Process.sleep(20)

      push(socket, "drawing_stroke", %{"segment" => "M 30 40", "color" => "#EF4444", "width" => 5})

      Process.sleep(20)

      {:ok, state} = RoomServer.get_state(room.id)
      assert length(state.drawing_strokes) == 2

      ref = push(socket, "drawing_undo", %{})
      assert_reply ref, :ok, %{status: "undo_done"}

      {:ok, state} = RoomServer.get_state(room.id)
      assert length(state.drawing_strokes) == 1
      [stroke] = state.drawing_strokes
      assert stroke.path == "M 10 20"
    end

    test "undo on empty strokes is a noop", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_undo", %{})
      assert_reply ref, :ok, _

      {:ok, state} = RoomServer.get_state(room.id)
      assert state.drawing_strokes == []
    end
  end

  describe "get_drawing_path (now returns strokes)" do
    test "returns strokes array from RoomServer", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      RoomServer.append_drawing(room.id, %{path: "M 100 200", color: "#3B82F6", width: 10})

      ref = push(socket, "get_drawing_path", %{})
      assert_reply ref, :ok, %{strokes: strokes}
      assert length(strokes) == 1
    end

    test "returns empty strokes when no drawing exists", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "get_drawing_path", %{})
      assert_reply ref, :ok, %{strokes: []}
    end
  end
end
