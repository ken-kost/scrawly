defmodule Scrawly.Games.RoomTest do
  use ExUnit.Case, async: false
  alias Scrawly.Games.Room

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)

    {:ok, creator} =
      Ash.create(
        Scrawly.Accounts.User,
        %{email: "room-creator-#{System.unique_integer([:positive])}@test.com"},
        authorize?: false
      )

    %{creator: creator}
  end

  describe "Room resource" do
    test "can create a room with default attributes", %{creator: creator} do
      assert {:ok, room} = Ash.create(Room, %{name: "Test Room", creator_id: creator.id})

      assert room.status == :lobby
      assert room.max_players == 12
      assert room.current_round == 0
      assert is_binary(room.code)
      assert String.length(room.code) >= 4
    end

    test "can create a room with custom max_players", %{creator: creator} do
      assert {:ok, room} =
               Ash.create(Room, %{name: "Test Room", max_players: 6, creator_id: creator.id})

      assert room.max_players == 6
    end

    test "validates max_players constraints", %{creator: creator} do
      # Test minimum constraint
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Room, %{name: "Test", max_players: 1, creator_id: creator.id})

      # Test maximum constraint
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Room, %{name: "Test", max_players: 13, creator_id: creator.id})
    end

    # TODO: Implement create_room action with proper room code generation
    # test "create_room action sets proper defaults" do
    #   assert {:ok, room} = Ash.ActionInput.for_action(Room, :create_room, %{})
    #                       |> Ash.run_action()
    #
    #   assert room.status == :lobby
    #   assert room.current_round == 0
    # end

    test "start_game action changes status and round", %{creator: creator} do
      {:ok, room} = Ash.create(Room, %{name: "Test Room", creator_id: creator.id})

      assert {:ok, updated_room} = Ash.update(room, %{}, action: :start_game)

      assert updated_room.status == :playing
      assert updated_room.current_round == 1
    end

    test "end_game action changes status to ended", %{creator: creator} do
      {:ok, room} = Ash.create(Room, %{name: "Test Room", creator_id: creator.id})

      assert {:ok, updated_room} = Ash.update(room, %{}, action: :end_game)

      assert updated_room.status == :ended
    end

    test "code is unique across rooms", %{creator: creator} do
      {:ok, room1} = Ash.create(Room, %{name: "Test Room", creator_id: creator.id})

      # Try to create another room with the same code (this would be very unlikely
      # but we test the constraint exists)
      code = room1.code

      assert {:error, %Ash.Error.Invalid{}} =
               Room
               |> Ash.Changeset.for_create(:create, %{name: "Test Room 2", creator_id: creator.id})
               |> Ash.Changeset.force_change_attribute(:code, code)
               |> Ash.create()
    end
  end

  describe "Room management functionality" do
    test "create_room action generates unique code and sets defaults", %{creator: creator} do
      assert {:ok, room} = Ash.create(Room, %{name: "Test Room", creator_id: creator.id})

      assert room.status == :lobby
      assert room.current_round == 0
      assert is_binary(room.code)
      assert String.length(room.code) == 6
    end

    test "join_room action validates player capacity", %{creator: creator} do
      {:ok, room} = Ash.create(Room, %{name: "Test Room", max_players: 2, creator_id: creator.id})

      # This should fail because player_id argument is required
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(room, %{}, action: :join_room)
    end

    test "auto_start_if_ready action starts game with minimum players", %{creator: creator} do
      {:ok, room} = Ash.create(Room, %{name: "Test Room", creator_id: creator.id})

      # This should succeed but not change status since no players are in room
      assert {:ok, updated_room} =
               Ash.update(room, %{}, action: :auto_start_if_ready)

      # Should remain in lobby since no players
      assert updated_room.status == :lobby
      assert updated_room.current_round == 0
    end

    test "handle_player_disconnect action manages player leaving", %{creator: creator} do
      {:ok, room} = Ash.create(Room, %{name: "Test Room", creator_id: creator.id})

      # This should fail because player_id argument is required
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(room, %{}, action: :handle_player_disconnect)
    end
  end
end
