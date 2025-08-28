defmodule Scrawly.Games.GameTest do
  use ExUnit.Case, async: false
  alias Scrawly.Games.{Game, Room}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
  end

  describe "Game resource" do
    setup do
      {:ok, room} = Ash.create(Room, %{})
      %{room: room}
    end

    test "can create a game with default attributes", %{room: room} do
      assert {:ok, game} = Ash.create(Game, %{room_id: room.id})

      assert game.status == :in_progress
      assert game.current_round == 1
      assert game.total_rounds == 5
      assert game.room_id == room.id
    end

    test "start_game action sets proper attributes", %{room: room} do
      assert {:ok, game} =
               Ash.create(
                 Game,
                 %{
                   room_id: room.id,
                   total_rounds: 3
                 },
                 action: :start_game
               )

      assert game.status == :in_progress
      assert game.current_round == 1
      assert game.total_rounds == 3
      assert game.room_id == room.id
    end

    test "next_round action increments current_round", %{room: room} do
      {:ok, game} = Ash.create(Game, %{room_id: room.id})

      assert {:ok, updated_game} = Ash.update(game, %{}, action: :next_round)

      assert updated_game.current_round == game.current_round + 1
    end

    test "end_game action changes status to completed", %{room: room} do
      {:ok, game} = Ash.create(Game, %{room_id: room.id})

      assert {:ok, updated_game} = Ash.update(game, %{}, action: :end_game)

      assert updated_game.status == :completed
    end

    test "validates total_rounds constraints", %{room: room} do
      # Test minimum constraint
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Game, %{
                 room_id: room.id,
                 total_rounds: 0
               })

      # Test maximum constraint
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Game, %{
                 room_id: room.id,
                 total_rounds: 11
               })
    end

    test "validates current_round constraints", %{room: room} do
      # Test minimum constraint
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Game, %{
                 room_id: room.id,
                 current_round: 0
               })
    end

    test "game belongs to a room", %{room: room} do
      {:ok, game} = Ash.create(Game, %{room_id: room.id})

      loaded_game = Ash.load!(game, :room)
      assert loaded_game.room.id == room.id
    end
  end
end
