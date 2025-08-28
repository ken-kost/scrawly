defmodule Scrawly.Games.RoomTest do
  use ExUnit.Case, async: false
  alias Scrawly.Games.Room

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
  end

  describe "Room resource" do
    test "can create a room with default attributes" do
      assert {:ok, room} = Ash.create(Room, %{})

      assert room.status == :lobby
      assert room.max_players == 12
      assert room.current_round == 0
      assert is_binary(room.code)
      assert String.length(room.code) >= 4
    end

    test "can create a room with custom max_players" do
      assert {:ok, room} = Ash.create(Room, %{max_players: 6})
      assert room.max_players == 6
    end

    test "validates max_players constraints" do
      # Test minimum constraint
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Room, %{max_players: 1})

      # Test maximum constraint
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Room, %{max_players: 13})
    end

    # TODO: Implement create_room action with proper room code generation
    # test "create_room action sets proper defaults" do
    #   assert {:ok, room} = Ash.ActionInput.for_action(Room, :create_room, %{})
    #                       |> Ash.run_action()
    #
    #   assert room.status == :lobby
    #   assert room.current_round == 0
    # end

    test "start_game action changes status and round" do
      {:ok, room} = Ash.create(Room, %{})

      assert {:ok, updated_room} = Ash.update(room, %{}, action: :start_game)

      assert updated_room.status == :playing
      assert updated_room.current_round == 1
    end

    test "end_game action changes status to ended" do
      {:ok, room} = Ash.create(Room, %{})

      assert {:ok, updated_room} = Ash.update(room, %{}, action: :end_game)

      assert updated_room.status == :ended
    end

    test "code is unique across rooms" do
      {:ok, room1} = Ash.create(Room, %{})

      # Try to create another room with the same code (this would be very unlikely
      # but we test the constraint exists)
      code = room1.code

      assert {:error, %Ash.Error.Invalid{}} =
               Room
               |> Ash.Changeset.for_create(:create, %{})
               |> Ash.Changeset.force_change_attribute(:code, code)
               |> Ash.create()
    end
  end
end
