defmodule Scrawly.Games.RoomManagementTest do
  use ExUnit.Case, async: false
  alias Scrawly.Games
  alias Scrawly.Accounts.User

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
  end

  describe "Room management with players" do
    setup do
      # Create test users
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
      # Test the code interface
      assert {:ok, room} = Games.create_room(%{})

      assert room.status == :lobby
      assert room.current_round == 0
      assert is_binary(room.code)
      assert String.length(room.code) == 6
      assert room.max_players == 12
    end

    test "create_room with custom max_players using code interface", %{user1: _user1} do
      assert {:ok, room} = Games.create_room(%{max_players: 6})

      assert room.max_players == 6
      assert room.status == :lobby
    end

    test "get_room_by_code using code interface", %{user1: _user1} do
      {:ok, room} = Games.create_room(%{})

      assert {:ok, found_room} = Games.get_room_by_code(room.code)
      assert found_room.id == room.id
    end

    test "join_room validates capacity", %{user1: user1, user2: user2, user3: user3} do
      # Create room with max 2 players
      {:ok, room} = Games.create_room(%{max_players: 2})

      # First player joins successfully
      {:ok, _user1} =
        Ash.update(user1, %{current_room_id: room.id, username: "Player1"}, action: :join_room)

      # Second player joins successfully
      {:ok, _user2} =
        Ash.update(user2, %{current_room_id: room.id, username: "Player2"}, action: :join_room)

      # Third player should fail due to capacity
      result =
        Ash.update(user3, %{current_room_id: room.id, username: "Player3"}, action: :join_room)

      # The join should succeed at the user level, but room.join_room should validate capacity
      assert {:ok, _} = result

      # Now test room-level join validation
      assert {:error, %Ash.Error.Invalid{}} =
               Games.join_room(room, user3.id)
    end

    test "auto_start_if_ready starts game with 2+ players", %{user1: user1, user2: user2} do
      {:ok, room} = Games.create_room(%{})

      # Add two players to the room
      {:ok, _user1} =
        Ash.update(user1, %{current_room_id: room.id, username: "Player1"}, action: :join_room)

      {:ok, _user2} =
        Ash.update(user2, %{current_room_id: room.id, username: "Player2"}, action: :join_room)

      # Auto-start should now transition to playing
      assert {:ok, updated_room} = Games.auto_start_if_ready(room)

      assert updated_room.status == :playing
      assert updated_room.current_round == 1
    end

    test "auto_start_if_ready does not start with insufficient players", %{user1: user1} do
      {:ok, room} = Games.create_room(%{})

      # Add only one player
      {:ok, _user1} =
        Ash.update(user1, %{current_room_id: room.id, username: "Player1"}, action: :join_room)

      # Auto-start should not change status
      assert {:ok, updated_room} = Games.auto_start_if_ready(room)

      assert updated_room.status == :lobby
      assert updated_room.current_round == 0
    end

    test "handle_player_disconnect resets room when empty", %{user1: user1} do
      {:ok, room} = Games.create_room(%{})

      # Add one player
      {:ok, _user1} =
        Ash.update(user1, %{current_room_id: room.id, username: "Player1"}, action: :join_room)

      # Start the game
      {:ok, room} = Games.start_game(room)
      assert room.status == :playing

      # Handle disconnect - should reset room since it becomes empty
      assert {:ok, updated_room} = Games.handle_player_disconnect(room, user1.id)

      assert updated_room.status == :lobby
      assert updated_room.current_round == 0
    end

    test "handle_player_disconnect ends game with only one player remaining", %{
      user1: user1,
      user2: user2
    } do
      {:ok, room} = Games.create_room(%{})

      # Add two players
      {:ok, _user1} =
        Ash.update(user1, %{current_room_id: room.id, username: "Player1"}, action: :join_room)

      {:ok, _user2} =
        Ash.update(user2, %{current_room_id: room.id, username: "Player2"}, action: :join_room)

      # Start the game
      {:ok, room} = Games.start_game(room)
      assert room.status == :playing

      # Handle disconnect - should end game since only one player remains
      assert {:ok, updated_room} = Games.handle_player_disconnect(room, user1.id)

      assert updated_room.status == :ended
    end

    test "join_room fails when room is not in lobby", %{user1: user1} do
      {:ok, room} = Games.create_room(%{})

      # Start the game (bypass normal flow for testing)
      {:ok, room} = Games.start_game(room)
      assert room.status == :playing

      # Try to join - should fail
      assert {:error, %Ash.Error.Invalid{}} =
               Games.join_room(room, user1.id)
    end
  end
end
