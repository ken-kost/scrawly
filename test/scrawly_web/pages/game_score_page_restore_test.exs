defmodule ScrawlyWeb.Pages.GameScorePageRestoreTest do
  @moduledoc """
  The score page's countdown back to the room (QA C4): it runs only for the
  game the room has just finished and for one of the room's players, and a
  Back/Forward restore asks the room again instead of resuming a dead chain.
  Plus the page's texts: not found, ties, the countdown's label.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Component
  alias Hologram.Component.Action
  alias Hologram.Template.Renderer
  alias Scrawly.Games
  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.GameScorePage

  @moduletag :capture_log

  # The page param is a prop on the client.
  defp init_page(game_id, server) do
    {component, server} =
      GameScorePage.init(%{game_id: game_id}, %Component{props: %{game_id: game_id}}, server)

    {%{component | props: %{game_id: game_id}}, server}
  end

  defp page_server(user), do: %{server_for(user) | cid: "page", instance_id: "i-1"}

  defp render(state) do
    {html, _registry, _server} =
      GameScorePage.template().(state)
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  # A finished game: the room in :post_game, creator and player in it.
  defp finish_game!(room, creator) do
    {:ok, _} = RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"]})
    {:ok, ended} = RoomServer.end_game(room.id)
    ended.last_game_id
  end

  defp room_pid(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp counting?({component, server}, room) do
    on? = component.next_action == %Action{name: :start_countdown}
    subscribed? = Enum.any?(server.subscriptions, &(elem(&1, 0) == {:room, room.id}))
    assert on? == subscribed?
    assert component.state.room_dissolved == not on?
    on?
  end

  setup do
    creator = create_user()
    player = create_user()
    room = start_room(creator)
    {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})
    # A DB member too, as the join command makes it: the room keeps its
    # players when it returns to the lobby.
    Scrawly.Accounts.join_room!(player, room.id)
    Games.join_room!(room.id, player.id)
    %{creator: creator, player: player, room: room}
  end

  describe "who gets the countdown" do
    test "the room's players, for the game the room has just finished", ctx do
      game_id = finish_game!(ctx.room, ctx.creator)

      assert counting?(init_page(game_id, server_for(ctx.player)), ctx.room)
      assert counting?(init_page(game_id, server_for(ctx.creator)), ctx.room)

      # Someone who watched (or anyone else) only gets "back to home".
      refute counting?(init_page(game_id, server_for(create_user())), ctx.room)
      refute counting?(init_page(game_id, anon_server()), ctx.room)
    end

    test "never for an older game of the room", ctx do
      old_game = finish_game!(ctx.room, ctx.creator)
      send(room_pid(ctx.room), :return_to_lobby)
      _ = room_state!(ctx.room.id)
      new_game = finish_game!(ctx.room, ctx.creator)

      refute counting?(init_page(old_game, server_for(ctx.player)), ctx.room)
      assert counting?(init_page(new_game, server_for(ctx.player)), ctx.room)
    end

    test "a player who left the room is not sent back to it", ctx do
      game_id = finish_game!(ctx.room, ctx.creator)
      {:ok, _} = RoomServer.leave(ctx.room.id, ctx.player.id)

      refute counting?(init_page(game_id, server_for(ctx.player)), ctx.room)
    end

    test "a room process restarted in :post_game (no last_game_id) uses the room's latest game",
         ctx do
      old_game = finish_game!(ctx.room, ctx.creator)
      send(room_pid(ctx.room), :return_to_lobby)
      _ = room_state!(ctx.room.id)
      new_game = finish_game!(ctx.room, ctx.creator)
      :sys.replace_state(room_pid(ctx.room), &%{&1 | last_game_id: nil})

      assert counting?(init_page(new_game, server_for(ctx.player)), ctx.room)
      refute counting?(init_page(old_game, server_for(ctx.player)), ctx.room)
    end
  end

  describe "Back/Forward restore" do
    setup ctx do
      game_id = finish_game!(ctx.room, ctx.creator)
      {component, _server} = init_page(game_id, server_for(ctx.player))
      # The runtime takes the queued action off the component once it runs.
      shown = GameScorePage.action(:page_shown, %{}, %{component | next_action: nil})
      %{game_id: game_id, shown: shown}
    end

    test "the first :page_shown only marks the page", %{shown: shown} do
      assert shown.state.page_shown? == true
      assert shown.next_command == nil
    end

    test "a counting page asks the room again with a new chain", ctx do
      # Left through the countdown's own navigation: `leaving` was set.
      left = %{ctx.shown | state: %{ctx.shown.state | leaving: true}}
      restored = GameScorePage.action(:page_shown, %{}, left)
      gen = ctx.shown.state.tick_gen + 1

      assert restored.state.leaving == false
      assert restored.state.tick_gen == gen
      assert restored.next_command.name == :resync_countdown

      assert restored.next_command.params == %{
               room_id: ctx.room.id,
               game_id: ctx.game_id,
               gen: gen,
               stale_rooms: []
             }

      # Still in the window: the remaining time, the room's channel again,
      # :lobby (and any other room the tab listed) dropped.
      stale = Ecto.UUID.generate()
      params = Map.put(restored.next_command.params, :stale_rooms, [stale])
      reply = GameScorePage.command(:resync_countdown, params, page_server(ctx.player))

      assert %{name: :countdown_resynced, params: %{gen: ^gen, remaining_ms: ms}} =
               reply.next_action

      assert ms > 25_000 and ms <= 30_000
      ops = reply.__meta__.subscription_ops
      assert ops[{{:room, ctx.room.id}, "page"}] == :put
      assert ops[{{:room, stale}, "page"}] == :delete
      assert ops[{:lobby, "page"}] == :delete

      # The reply restarts the countdown (a new anchor and tick chain).
      resynced = GameScorePage.action(:countdown_resynced, reply.next_action.params, restored)
      assert resynced.state.room_dissolved == false
      assert resynced.state.countdown in [29, 30]
      assert resynced.next_action == %Action{name: :start_countdown}

      started = GameScorePage.action(:start_countdown, %{}, %{resynced | next_action: nil})
      assert started.next_action.name == :countdown_tick
      assert started.next_action.params == %{gen: gen}
    end

    test "once the window is over, it shows back to home and never navigates", ctx do
      send(room_pid(ctx.room), :return_to_lobby)
      _ = room_state!(ctx.room.id)

      restored = GameScorePage.action(:page_shown, %{}, ctx.shown)
      params = restored.next_command.params
      reply = GameScorePage.command(:resync_countdown, params, page_server(ctx.player))

      assert reply.next_action.name == :room_gone
      assert reply.__meta__.subscription_ops[{{:room, ctx.room.id}, "page"}] == :delete

      gone = GameScorePage.action(:room_gone, reply.next_action.params, restored)
      assert gone.state.room_dissolved == true
      assert gone.next_page == nil
      assert gone.next_action == nil

      # A late reply for another chain changes nothing.
      stale = GameScorePage.action(:countdown_resynced, %{gen: 1, remaining_ms: 9_000}, gone)
      assert stale == gone
    end

    test "a page that wasn't counting only drops the stale subscriptions", ctx do
      {component, _server} = init_page(ctx.game_id, server_for(create_user()))
      shown = GameScorePage.action(:page_shown, %{}, component)
      restored = GameScorePage.action(:page_shown, %{}, shown)

      assert restored.next_command.name == :drop_stale_subscriptions
      assert restored.next_command.params == %{stale_rooms: []}
    end

    test ":resync_countdown with malformed params is denied", ctx do
      for params <- [%{}, %{room_id: "x", game_id: "y"}, %{room_id: ctx.room.id}, "junk"] do
        reply = GameScorePage.command(:resync_countdown, params, page_server(ctx.player))
        assert reply.next_action.name == :command_denied
      end
    end
  end

  describe "texts" do
    setup ctx do
      {:ok, room} =
        Games.create_room(%{name: "TEST texts", max_players: 4, creator_id: ctx.creator.id})

      {:ok, game} = Games.create_game(room.id, 2)
      %{game: game, texts_room: room}
    end

    defp result!(ctx, user, score) do
      {:ok, _} =
        Games.create_game_result(%{
          player_id: user.id,
          game_id: ctx.game.id,
          room_id: ctx.texts_room.id,
          score: score,
          player_username: user.username
        })
    end

    test "a shared top score is a tie, not a win", ctx do
      result!(ctx, ctx.creator, 120)
      result!(ctx, ctx.player, 120)
      {component, _} = init_page(ctx.game.id, server_for(ctx.player))

      [first, second] = Enum.map(component.state.results, & &1.player_username)
      assert component.state.headline == "#{first} and #{second} tie."
      refute render(component.state) =~ "wins."
    end

    test "one top score wins; nobody scoring says so", ctx do
      third = create_user()
      result!(ctx, ctx.creator, 200)
      result!(ctx, ctx.player, 120)
      result!(ctx, third, 120)
      {component, _} = init_page(ctx.game.id, server_for(ctx.player))
      assert component.state.headline == "#{ctx.creator.username} wins."

      {:ok, game} = Games.create_game(ctx.texts_room.id, 2)

      for user <- [ctx.creator, ctx.player] do
        {:ok, _} =
          Games.create_game_result(%{
            player_id: user.id,
            game_id: game.id,
            room_id: ctx.texts_room.id,
            score: 0,
            player_username: user.username
          })
      end

      {zero, _} = init_page(game.id, server_for(ctx.player))
      assert zero.state.headline == "no one scored."
    end

    test "the countdown says where it goes: back to the lobby", ctx do
      game_id = finish_game!(ctx.room, ctx.creator)
      {component, _} = init_page(game_id, server_for(ctx.player))
      html = render(component.state)

      assert html =~ "back to the lobby in"
      refute html =~ "next round in"
    end

    test "an unknown game says not found", ctx do
      for game_id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        {component, server} = init_page(game_id, server_for(ctx.player))

        assert component.state.not_found? == true
        assert component.next_action == nil
        assert server.subscriptions == []

        html = render(component.state)
        assert html =~ "game not found."
        refute html =~ "room Unknown"
        refute html =~ "final standings"
      end

      {found, _} = init_page(ctx.game.id, server_for(ctx.player))
      assert found.state.not_found? == false
      refute render(found.state) =~ "game not found."
    end
  end
end
