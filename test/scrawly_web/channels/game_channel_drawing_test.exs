defmodule ScrawlyWeb.GameChannelDrawingTest do
  use ScrawlyWeb.ChannelCase

  alias ScrawlyWeb.GameChannel
  alias Scrawly.Accounts
  alias Scrawly.Games

  setup do
    # Create a test user
    {:ok, user} =
      Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "test-#{System.unique_integer([:positive])}@example.com"
      })
      |> Ash.create(authorize?: false)

    # Create a test room
    {:ok, room} =
      Games.Room
      |> Ash.Changeset.for_create(:create, %{
        code: "TEST#{:rand.uniform(1000)}",
        max_players: 8
      })
      |> Ash.create()

    # Create a valid token for the user
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    {:ok, socket} = connect(ScrawlyWeb.UserSocket, %{"token" => token})

    %{socket: socket, user: user, room: room}
  end

  describe "drawing events" do
    test "handles drawing_start event", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_start", %{"x" => 100, "y" => 150})
      assert_reply ref, :ok, %{status: "drawing_started"}

      assert_broadcast "drawing_start", %{
        "x" => 100,
        "y" => 150,
        "player_id" => _player_id
      }
    end

    test "handles drawing_move event", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_move", %{"x" => 120, "y" => 160})
      assert_reply ref, :ok, %{status: "drawing_moved"}

      assert_broadcast "drawing_move", %{
        "x" => 120,
        "y" => 160,
        "player_id" => _player_id
      }
    end

    test "handles drawing_stop event", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_stop", %{})
      assert_reply ref, :ok, %{status: "drawing_stopped"}

      assert_broadcast "drawing_stop", %{
        "player_id" => _player_id
      }
    end

    test "drawing events are not sent to the drawer", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      # The drawer should not receive their own drawing events (broadcast_from)
      push(socket, "drawing_start", %{"x" => 100, "y" => 150})
      refute_push "drawing_start", %{}
    end
  end
end
