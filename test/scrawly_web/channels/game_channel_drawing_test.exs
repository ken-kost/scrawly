defmodule ScrawlyWeb.GameChannelDrawingTest do
  use ScrawlyWeb.ChannelCase

  alias ScrawlyWeb.GameChannel
  alias Scrawly.Accounts
  alias Scrawly.Games

  setup do
    {:ok, user} =
      Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "test-#{System.unique_integer([:positive])}@example.com"
      })
      |> Ash.create(authorize?: false)

    {:ok, room} =
      Games.Room
      |> Ash.Changeset.for_create(:create, %{
        name: "Test Room",
        max_players: 8
      })
      |> Ash.create()

    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    {:ok, socket} = connect(ScrawlyWeb.UserSocket, %{"token" => token})

    %{socket: socket, user: user, room: room}
  end

  describe "drawing events" do
    test "drawing_start returns ok reply", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_start", %{"x" => 100, "y" => 150})
      assert_reply ref, :ok, %{status: "drawing_started"}
    end

    test "drawing_move returns ok reply", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_move", %{"x" => 120, "y" => 160})
      assert_reply ref, :ok, %{status: "drawing_moved"}
    end

    test "drawing_stop returns ok reply", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "drawing_stop", %{})
      assert_reply ref, :ok, %{status: "drawing_stopped"}
    end
  end

  describe "round timer events" do
    test "get_timer_status returns remaining time", %{socket: socket, room: room} do
      {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      ref = push(socket, "get_timer_status", %{"game_id" => "non-existent"})
      assert_reply ref, :ok, %{remaining_seconds: _}
    end
  end
end
