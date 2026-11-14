defmodule ScrawlyWeb.Pages.GameScorePageAuthzTest do
  @moduledoc """
  GameScorePage's `:dissolve_room` and `:leave_room` act only for the session
  user (ScrawlyWeb.Auth), never for ids taken from params.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.{GamePage, GameScorePage}

  @moduletag :capture_log

  setup do
    creator = create_user()
    player = create_user()
    stranger = create_user()
    room = start_room(creator)

    joined = GamePage.command(:join_room, %{room_id: room.id}, server_for(player))
    assert joined.next_action.name == :room_refreshed

    player = Ash.update!(reload_user!(player), %{score: 12}, action: :update_score)
    %{creator: creator, player: player, stranger: stranger, room: room}
  end

  defp assert_denied(result, reason) do
    assert result.next_action.name == :command_denied
    assert result.next_action.params.reason == reason
    assert result.broadcasts == []
  end

  defp assert_room_untouched(%{room: room, creator: creator, player: player}) do
    assert RoomServer.room_exists?(room.id)
    assert Enum.map(room_state!(room.id).players, & &1.id) == [creator.id, player.id]
    assert reload_room!(room).status == :lobby

    reloaded = reload_user!(player)
    assert reloaded.current_room_id == room.id
    assert reloaded.score == 12
    assert reload_user!(creator).current_room_id == room.id
  end

  describe ":dissolve_room" do
    test "a player who isn't the creator is denied and nothing changes", ctx do
      result =
        GameScorePage.command(
          :dissolve_room,
          %{room_id: ctx.room.id, user_id: ctx.creator.id},
          server_for(ctx.player)
        )

      assert_denied(result, :not_creator)
      assert_room_untouched(ctx)
    end

    test "a stranger is denied", ctx do
      result =
        GameScorePage.command(:dissolve_room, %{room_id: ctx.room.id}, server_for(ctx.stranger))

      assert_denied(result, :not_creator)
      assert_room_untouched(ctx)
    end

    test "an account-less visitor is denied", ctx do
      result = GameScorePage.command(:dissolve_room, %{room_id: ctx.room.id}, anon_server("x"))

      assert_denied(result, :unauthenticated)
      assert_room_untouched(ctx)
    end

    test "the creator dissolves the room", %{room: room, creator: creator, player: player} do
      result = GameScorePage.command(:dissolve_room, %{room_id: room.id}, server_for(creator))

      assert result.next_action.name == :room_dissolved_confirmed
      assert_room_stopped(room.id)
      assert reload_room!(room).status == :ended
      assert reload_user!(player).current_room_id == nil
      assert reload_user!(creator).current_room_id == nil
    end

    test "without a RoomServer, only the DB creator may dissolve", ctx do
      %{room: room, creator: creator, player: player} = ctx
      stop_room(room.id)

      denied = GameScorePage.command(:dissolve_room, %{room_id: room.id}, server_for(player))
      assert_denied(denied, :not_creator)
      assert reload_room!(room).status == :lobby
      assert reload_user!(player).current_room_id == room.id
      assert reload_user!(player).score == 12

      ok = GameScorePage.command(:dissolve_room, %{room_id: room.id}, server_for(creator))
      assert ok.next_action.name == :room_dissolved_confirmed
      assert reload_room!(room).status == :ended
    end

    test "an unknown room is denied as not found", %{creator: creator} do
      result =
        GameScorePage.command(
          :dissolve_room,
          %{room_id: Ecto.UUID.generate()},
          server_for(creator)
        )

      assert_denied(result, :not_found)
    end
  end

  describe ":leave_room" do
    test "removes only the session user, never a forged one", ctx do
      %{room: room, creator: creator, player: player} = ctx

      params = %{room_id: room.id, user_id: creator.id}
      result = GameScorePage.command(:leave_room, params, server_for(player))

      assert result.next_action.name == :left_room
      assert RoomServer.room_exists?(room.id)
      assert Enum.map(room_state!(room.id).players, & &1.id) == [creator.id]
      assert reload_user!(player).current_room_id == nil
      assert reload_user!(creator).current_room_id == room.id
      assert reload_room!(room).status == :lobby
    end

    test "the creator leaving dissolves the room", %{room: room, creator: creator} do
      result = GameScorePage.command(:leave_room, %{room_id: room.id}, server_for(creator))

      assert result.next_action.name == :left_room
      assert_room_stopped(room.id)
      assert reload_room!(room).status == :ended
    end

    test "after :return_to_lobby emptied the players, leaving still succeeds", ctx do
      %{room: room, creator: creator, player: player} = ctx
      {:ok, _} = RoomServer.end_game(room.id)
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
      send(pid, :return_to_lobby)
      assert room_state!(room.id).players == []

      result = GameScorePage.command(:leave_room, %{room_id: room.id}, server_for(player))

      assert result.next_action.name == :left_room
      assert RoomServer.room_exists?(room.id)
      assert reload_user!(player).current_room_id == nil
      assert reload_user!(creator).current_room_id == room.id
    end

    test "a stranger leaving changes nothing", ctx do
      result =
        GameScorePage.command(:leave_room, %{room_id: ctx.room.id}, server_for(ctx.stranger))

      assert result.next_action.name == :left_room
      assert_room_untouched(ctx)
    end

    test "an account-less visitor just navigates", ctx do
      result = GameScorePage.command(:leave_room, %{room_id: ctx.room.id}, anon_server("x"))

      assert result.next_action.name == :left_room
      assert_room_untouched(ctx)
    end
  end

  describe "client" do
    test ":leave_room sends only the room id" do
      component = %Hologram.Component{state: %{room_id: "r1", current_user_id: "u1"}}

      command = GameScorePage.action(:leave_room, %{}, component).next_command

      assert {command.name, command.params} == {:leave_room, %{room_id: "r1"}}
    end

    test ":command_denied is a no-op" do
      component = %Hologram.Component{state: %{room_id: "r1"}}

      assert GameScorePage.action(:command_denied, %{reason: :not_creator}, component) ==
               component
    end
  end
end
