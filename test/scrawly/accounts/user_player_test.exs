defmodule Scrawly.Accounts.UserPlayerTest do
  use ExUnit.Case, async: false
  alias Scrawly.Accounts.User
  alias Scrawly.Games.Room

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
  end

  describe "User player functionality" do
    setup do
      {:ok, room} = Ash.create(Room, %{})
      # Create a simple user for testing player functionality
      {:ok, user} = Ash.create(User, %{email: "test@example.com"}, authorize?: false)
      %{room: room, user: user}
    end

    test "user has default player attributes", %{user: user} do
      assert user.score == 0
      assert user.player_state == :disconnected
      assert is_nil(user.current_room_id)
      assert is_nil(user.username)
    end

    test "join_room action updates player state and room", %{room: room, user: user} do
      assert {:ok, updated_user} =
               Ash.update(
                 user,
                 %{
                   current_room_id: room.id,
                   username: "TestPlayer"
                 },
                 action: :join_room,
                 actor: user
               )

      assert updated_user.current_room_id == room.id
      assert updated_user.username == "TestPlayer"
      assert updated_user.player_state == :connected
    end

    test "leave_room action resets player state", %{room: room, user: user} do
      # First join a room
      {:ok, user_in_room} =
        Ash.update(
          user,
          %{
            current_room_id: room.id,
            username: "TestPlayer"
          },
          action: :join_room
        )

      # Then leave the room
      assert {:ok, updated_user} = Ash.update(user_in_room, %{}, action: :leave_room)

      assert is_nil(updated_user.current_room_id)
      assert updated_user.player_state == :disconnected
      assert updated_user.score == 0
    end

    test "update_score action changes user score", %{user: user} do
      assert {:ok, updated_user} =
               Ash.update(
                 user,
                 %{
                   score: 150
                 },
                 action: :update_score
               )

      assert updated_user.score == 150
    end

    test "set_player_state action changes player state", %{user: user} do
      assert {:ok, updated_user} =
               Ash.update(
                 user,
                 %{
                   player_state: :drawing
                 },
                 action: :set_player_state
               )

      assert updated_user.player_state == :drawing
    end

    test "validates username constraints", %{user: user} do
      # Test minimum length constraint
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(
                 user,
                 %{
                   # Too short
                   username: "a"
                 },
                 action: :join_room
               )

      # Test maximum length constraint
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(
                 user,
                 %{
                   # Too long
                   username: String.duplicate("a", 21)
                 },
                 action: :join_room
               )
    end

    test "validates score constraints", %{user: user} do
      # Test minimum constraint
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(
                 user,
                 %{
                   # Negative score not allowed
                   score: -1
                 },
                 action: :update_score
               )
    end

    test "validates player_state constraints", %{user: user} do
      # Test invalid state
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(
                 user,
                 %{
                   player_state: :invalid_state
                 },
                 action: :set_player_state
               )
    end

    test "user can belong to a room", %{room: room, user: user} do
      {:ok, user_in_room} =
        Ash.update(
          user,
          %{
            current_room_id: room.id,
            username: "TestPlayer"
          },
          action: :join_room
        )

      loaded_user = Ash.load!(user_in_room, :current_room)
      assert loaded_user.current_room.id == room.id
    end
  end
end
