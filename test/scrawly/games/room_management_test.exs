defmodule Scrawly.Games.RoomManagementTest do
  use ExUnit.Case, async: false
  alias Scrawly.Games
  alias Scrawly.Accounts.User

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
  end

  describe "Room management with players" do
    setup do
      {:ok, user1} =
        Ash.create(User, %{email: "player1-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      {:ok, user2} =
        Ash.create(User, %{email: "player2-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      {:ok, user3} =
        Ash.create(User, %{email: "player3-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      %{user1: user1, user2: user2, user3: user3}
    end

    test "create_room using code interface", %{user1: _user1} do
      assert {:ok, room} = Games.create_room(%{name: "Test Room"})

      assert room.status == :lobby
      assert room.current_round == 0
      assert is_binary(room.code)
      assert String.length(room.code) == 6
      assert room.max_players == 12
    end

    test "create_room with custom max_players using code interface", %{user1: _user1} do
      assert {:ok, room} = Games.create_room(%{name: "Test Room", max_players: 6})

      assert room.max_players == 6
      assert room.status == :lobby
    end

    test "get_room_by_code using code interface", %{user1: _user1} do
      {:ok, room} = Games.create_room(%{name: "Test Room"})

      assert {:ok, found_room} = Games.get_room_by_code(room.code)
      assert found_room.id == room.id
    end

    test "join_room validates capacity", %{user1: user1, user2: user2, user3: user3} do
      {:ok, room} = Games.create_room(%{name: "Test Room", max_players: 2})

      {:ok, _user1} =
        Ash.update(user1, %{current_room_id: room.id}, action: :join_room)

      {:ok, _user2} =
        Ash.update(user2, %{current_room_id: room.id}, action: :join_room)

      result =
        Ash.update(user3, %{current_room_id: room.id}, action: :join_room)

      assert {:ok, _} = result

      assert {:error, %Ash.Error.Invalid{}} =
               Games.join_room(room, user3.id)
    end
  end
end
