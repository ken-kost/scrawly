defmodule ScrawlyWeb.Pages.GameScorePageTest do
  @moduledoc """
  The score page's client countdown: anchored on the time left reported by
  the room, re-scheduled with delayed actions, guarded by a per-page `gen`,
  and navigating to GamePage only once the server has left `:post_game`.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Component
  alias Hologram.Component.{Action, Command}
  alias Scrawly.Games
  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.{GamePage, GameScorePage, HomePage}

  @moduletag :capture_log

  @gen 4242
  @countdown_keys [
    :countdown_ms,
    :countdown,
    :countdown_total,
    :countdown_ends_at,
    :lobby_ready,
    :leaving,
    :recheck_attempts,
    :tick_gen,
    :room_dissolved
  ]

  defp now_ms, do: System.monotonic_time(:millisecond)

  # The page state while the countdown runs, ending `left_ms` from now.
  defp counting(attrs \\ []) do
    state =
      Map.merge(
        %{
          room_id: "room-1",
          countdown_ms: 0,
          countdown: 30,
          countdown_total: 30,
          countdown_ends_at: now_ms() + 30_000,
          lobby_ready: false,
          leaving: false,
          recheck_attempts: 0,
          tick_gen: @gen,
          room_dissolved: false
        },
        Map.new(attrs)
      )

    %Component{state: state}
  end

  defp ends_in(ms), do: [countdown_ends_at: now_ms() + ms]

  defp tick(component, gen \\ @gen),
    do: GameScorePage.action(:countdown_tick, %{gen: gen}, component)

  defp assert_navigates_to_room(result, room_id \\ "room-1") do
    assert result.next_page == {GamePage, room_id: room_id}
    assert result.next_action == nil
    assert result.next_command == nil
    assert result.state.leaving == true
  end

  # ── Pure client actions ──────────────────────────────────────────────

  describe ":start_countdown" do
    test "anchors the deadline on the client clock and schedules the first tick" do
      before = now_ms()
      result = GameScorePage.action(:start_countdown, %{}, counting(countdown_ms: 20_000))

      assert result.state.countdown_ends_at >= before + 20_000
      assert result.state.countdown_ends_at <= now_ms() + 20_000

      assert result.next_action == %Action{
               name: :countdown_tick,
               params: %{gen: @gen},
               delay: 1000
             }

      assert result.next_command == nil
    end
  end

  describe ":countdown_tick" do
    test "with time left, recomputes the seconds and re-puts itself with the same gen" do
      result = tick(counting(ends_in(5_500)))

      assert result.state.countdown == 6

      assert result.next_action == %Action{
               name: :countdown_tick,
               params: %{gen: @gen},
               delay: 1000
             }

      assert result.next_command == nil
      assert result.next_page == nil
    end

    test "recomputes from the anchor instead of decrementing (throttled timers)" do
      result = tick(counting(ends_in(12_200) ++ [countdown: 29]))
      assert result.state.countdown == 13
    end

    test "at zero puts exactly one :countdown_finished and schedules nothing" do
      result = tick(counting(ends_in(-1_500)))

      assert result.state.countdown == 0

      assert result.next_command == %Command{
               name: :countdown_finished,
               params: %{room_id: "room-1", gen: @gen}
             }

      assert result.next_action == nil
      assert result.next_page == nil
    end

    test "a stale gen, a dissolved room or a page being left ends the chain" do
      component = counting(ends_in(5_000))
      assert tick(component, @gen + 1) == component

      for attrs <- [[room_dissolved: true], [leaving: true]] do
        component = counting(ends_in(5_000) ++ attrs)
        assert tick(component) == component

        at_zero = counting(ends_in(-100) ++ attrs)
        assert tick(at_zero) == at_zero
      end
    end

    test "once the room is back in the lobby, only navigates to the room" do
      assert_navigates_to_room(tick(counting(ends_in(5_000) ++ [lobby_ready: true])))
    end
  end

  describe ":room_delta" do
    test ":lobby only records that the room is ready" do
      component = counting()
      result = GameScorePage.action(:room_delta, %{status: :lobby, version: 9}, component)

      assert result == %{component | state: %{component.state | lobby_ready: true}}
    end

    test ":ended shows back to home" do
      result = GameScorePage.action(:room_delta, %{status: :ended}, counting())

      assert result.state.room_dissolved == true
      assert result.state.countdown == 0
      assert {result.next_action, result.next_command, result.next_page} == {nil, nil, nil}
    end

    test "other statuses change nothing" do
      component = counting()

      for status <- [:post_game, :playing] do
        assert GameScorePage.action(:room_delta, %{status: status, players: []}, component) ==
                 component
      end
    end
  end

  test "the other {:room} broadcasts are no-ops" do
    component = counting()

    for {name, params} <- [
          chat_appended: %{message: %{id: 1, message: "hi"}},
          stroke_completed: %{stroke_id: "s1", path: "M0 0", color: "#000000", width: 2},
          drawing_cleared: %{},
          drawing_undone: %{strokes: []}
        ] do
      assert GameScorePage.action(name, params, component) == component
    end
  end

  describe "server confirmation" do
    test ":countdown_done navigates unless the page is already leaving or stale" do
      assert_navigates_to_room(GameScorePage.action(:countdown_done, %{gen: @gen}, counting()))

      for component <- [counting(leaving: true), counting(room_dissolved: true)] do
        assert GameScorePage.action(:countdown_done, %{gen: @gen}, component) == component
      end

      assert GameScorePage.action(:countdown_done, %{gen: 1}, counting()) == counting()
    end

    test ":room_gone shows back to home, unless it belongs to another page instance" do
      result = GameScorePage.action(:room_gone, %{gen: @gen}, counting(countdown: 3))
      assert result.state.room_dissolved == true
      assert result.state.countdown == 0

      component = counting()
      assert GameScorePage.action(:room_gone, %{gen: @gen + 1}, component) == component
    end

    test ":recheck_countdown re-asks at most 10 times, then shows back to home" do
      {component, sent} =
        Enum.reduce(1..10, {counting(countdown: 0), 0}, fn attempt, {component, sent} ->
          result = GameScorePage.action(:recheck_countdown, %{gen: @gen}, component)

          assert result.next_command == %Command{
                   name: :countdown_finished,
                   params: %{room_id: "room-1", gen: @gen}
                 }

          assert result.state.recheck_attempts == attempt
          {%{result | next_command: nil}, sent + 1}
        end)

      assert sent == 10

      result = GameScorePage.action(:recheck_countdown, %{gen: @gen}, component)
      assert result.state.room_dissolved == true
      assert {result.next_action, result.next_command, result.next_page} == {nil, nil, nil}
    end

    test ":recheck_countdown navigates once the room is ready and ignores stale gens" do
      assert_navigates_to_room(
        GameScorePage.action(:recheck_countdown, %{gen: @gen}, counting(lobby_ready: true))
      )

      component = counting()
      assert GameScorePage.action(:recheck_countdown, %{gen: 7}, component) == component
    end
  end

  describe "navigation" do
    test ":go_home goes straight to HomePage, without a command" do
      result = GameScorePage.action(:go_home, %{}, counting())

      assert result.next_page == HomePage
      assert result.next_command == nil
      assert result.state.leaving == true
    end

    test ":left_room and :room_dissolved_confirmed go home and end the countdown" do
      for name <- [:left_room, :room_dissolved_confirmed] do
        result = GameScorePage.action(name, %{}, counting())
        assert result.next_page == HomePage
        assert result.state.leaving == true
        assert tick(%{result | next_page: nil}) == %{result | next_page: nil}
      end
    end

    test "the drawing modal opens and closes" do
      component = %Component{state: %{modal_round: nil}}
      opened = GameScorePage.action(:open_drawing_modal, %{round: 2}, component)
      assert opened.state.modal_round == 2
      assert GameScorePage.action(:close_drawing_modal, %{}, opened).state.modal_round == nil
    end
  end

  # ── Live room: init and :countdown_finished ──────────────────────────

  describe "with a live room" do
    setup do
      creator = create_user()
      player = create_user()
      room = start_room(creator)
      {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})
      {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"]})
      on_exit(fn -> Games.stop_round_timer(started.game_id) end)
      {:ok, ended} = RoomServer.end_game(room.id)
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)

      %{room: room, creator: creator, player: player, game_id: ended.last_game_id, pid: pid}
    end

    defp init_page(ctx, user) do
      GameScorePage.init(%{game_id: ctx.game_id}, %Component{}, server_for(user))
    end

    defp finished(ctx, gen \\ @gen) do
      GameScorePage.command(
        :countdown_finished,
        %{room_id: ctx.room.id, gen: gen},
        server_for(ctx.player)
      )
    end

    test "init in :post_game starts the countdown from the room's time left", ctx do
      {component, server} = init_page(ctx, ctx.player)
      state = component.state

      for key <- @countdown_keys, do: assert(Map.has_key?(state, key), "missing #{key}")
      assert state.room_id == ctx.room.id
      assert state.room_dissolved == false
      assert state.countdown_ms > 28_000 and state.countdown_ms <= 30_000
      assert state.countdown in [29, 30]
      assert state.countdown_total == 30
      assert state.countdown_ends_at == nil
      assert {state.lobby_ready, state.leaving, state.recheck_attempts} == {false, false, 0}
      assert is_integer(state.tick_gen) and state.tick_gen > 0
      assert component.next_action == %Action{name: :start_countdown}
      assert component.next_page == nil

      assert Enum.any?(server.subscriptions, fn {channel, _cid} ->
               channel == {:room, ctx.room.id}
             end)

      {other, _server} = init_page(ctx, ctx.creator)
      assert other.state.tick_gen != state.tick_gen
      assert other.state.is_host == true
      assert state.is_host == false
    end

    test "a reload 10 s into the window shows about 20 s", ctx do
      :sys.replace_state(ctx.pid, &%{&1 | post_game_deadline: &1.post_game_deadline - 10_000})

      {component, _server} = init_page(ctx, ctx.player)
      assert component.state.countdown == 20
      assert component.state.countdown_ms > 19_000 and component.state.countdown_ms <= 20_000
    end

    test "init after the room went back to the lobby shows back to home", ctx do
      send(ctx.pid, :return_to_lobby)
      {component, server} = init_page(ctx, ctx.player)

      for key <- @countdown_keys, do: assert(Map.has_key?(component.state, key))
      assert component.state.room_dissolved == true
      assert component.state.countdown == 0
      assert component.next_action == nil
      assert server.subscriptions == []
    end

    test "init without a running room or for an unknown game shows back to home", ctx do
      stop_room(ctx.room.id)
      assert_room_stopped(ctx.room.id)

      {component, server} = init_page(ctx, ctx.player)
      assert component.state.room_dissolved == true
      assert component.next_action == nil
      assert server.subscriptions == []

      {unknown, _server} =
        GameScorePage.init(%{game_id: Ecto.UUID.generate()}, %Component{}, server_for(ctx.player))

      for key <- @countdown_keys, do: assert(Map.has_key?(unknown.state, key))
      assert unknown.state.room_id == nil
      assert unknown.state.room_dissolved == true
      assert unknown.next_action == nil
    end

    test ":countdown_finished asks for a recheck while still in :post_game", ctx do
      result = finished(ctx)

      assert result.next_action == %Action{
               name: :recheck_countdown,
               params: %{gen: @gen},
               delay: 500
             }

      assert result.broadcasts == []
    end

    test ":countdown_finished confirms once the room left :post_game", ctx do
      send(ctx.pid, :return_to_lobby)
      assert finished(ctx).next_action == %Action{name: :countdown_done, params: %{gen: @gen}}

      :sys.replace_state(ctx.pid, &%{&1 | status: :playing})
      assert finished(ctx).next_action == %Action{name: :countdown_done, params: %{gen: @gen}}
    end

    test ":countdown_finished reports an ended, stopped or unknown room as gone", ctx do
      :sys.replace_state(ctx.pid, &%{&1 | status: :ended})
      assert finished(ctx).next_action == %Action{name: :room_gone, params: %{gen: @gen}}

      stop_room(ctx.room.id)
      assert_room_stopped(ctx.room.id)
      assert finished(ctx).next_action == %Action{name: :room_gone, params: %{gen: @gen}}

      unknown = %{ctx | room: %{id: Ecto.UUID.generate()}}
      assert finished(unknown).next_action.name == :room_gone

      no_params = GameScorePage.command(:countdown_finished, %{}, server_for(ctx.player))
      assert no_params.next_action == %Action{name: :room_gone, params: %{gen: nil}}
    end

    test "a room stuck in :post_game costs at most 11 commands, then back to home", ctx do
      {component, _server} = init_page(ctx, ctx.player)
      gen = component.state.tick_gen

      component =
        GameScorePage.action(:start_countdown, %{}, %{component | next_action: nil})

      # The client's local zero, while the server still says :post_game.
      component = %{component | state: %{component.state | countdown_ends_at: now_ms() - 1}}
      component = tick(component, gen)

      {component, sent} = drive_commands(component, ctx, 0)

      assert sent == 11
      assert component.state.room_dissolved == true
      assert component.next_page == nil
    end

    test "the room returning to the lobby lands the viewer on GamePage", ctx do
      {component, _server} = init_page(ctx, ctx.player)
      gen = component.state.tick_gen
      component = GameScorePage.action(:start_countdown, %{}, %{component | next_action: nil})

      # Deadline reached on the server first: the broadcast arrives mid-countdown.
      send(ctx.pid, :return_to_lobby)
      component = GameScorePage.action(:room_delta, room_state!(ctx.room.id), component)
      assert component.next_page == nil

      result = tick(%{component | next_action: nil}, gen)
      assert_navigates_to_room(result, ctx.room.id)
    end

    test "a missed broadcast costs one command at local zero", ctx do
      {component, _server} = init_page(ctx, ctx.player)
      gen = component.state.tick_gen
      component = GameScorePage.action(:start_countdown, %{}, %{component | next_action: nil})

      send(ctx.pid, :return_to_lobby)
      component = %{component | state: %{component.state | countdown_ends_at: now_ms() - 1}}
      component = tick(%{component | next_action: nil}, gen)

      {done, sent} = drive_commands(component, ctx, 0)
      assert sent == 1
      assert_navigates_to_room(done, ctx.room.id)
    end
  end

  # Plays the client: sends each next_command through the page's command/3
  # and runs the action it replies with, until nothing is left to send.
  defp drive_commands(%{next_command: nil} = component, _ctx, sent), do: {component, sent}

  defp drive_commands(%{next_command: command} = component, ctx, sent) do
    reply = GameScorePage.command(command.name, command.params, server_for(ctx.player))
    action = reply.next_action
    component = %{component | next_command: nil, next_action: nil}
    result = GameScorePage.action(action.name, action.params, component)
    drive_commands(result, ctx, sent + 1)
  end
end
