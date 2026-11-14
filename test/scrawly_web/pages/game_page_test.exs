defmodule ScrawlyWeb.Pages.GamePageTest do
  # Shared sandbox: init/3 starts a RoomServer process that reads the DB.
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Template.Renderer
  alias Scrawly.Games
  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  setup do
    creator = create_user()
    room = start_room(creator)

    %{room: room, creator: creator}
  end

  describe "init/3" do
    test "initializes with room data for the creator", %{room: room, creator: creator} do
      assert {component, server} =
               GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(creator))

      assert %Hologram.Component{state: state} = component
      assert %Hologram.Server{} = server
      assert state.room_missing? == false
      # The page param stays a prop (component.props.room_id), never state.
      refute Map.has_key?(state, :room_id)
      assert state.room_code == room.code
      assert state.room_name == "Room #{room.name}"
      assert state.room_status == :lobby
      assert state.game_id == ""
      assert state.game_started == false
      assert [%{id: creator_id}] = state.players
      assert creator_id == creator.id
      assert state.is_creator == true
      assert state.current_user_id == creator.id
      assert state.time_left == 0
      assert state.choice_time_left == 0
      # Countdown anchors need the browser's clock: :mounted sets them.
      assert state.round_remaining_ms == 0
      assert state.choice_remaining_ms == 0
      assert state.choice_duration == 15
      assert state.round_deadline_local == nil
      assert state.choice_deadline_local == nil
      assert state.last_tick_at == nil
      assert is_integer(state.tick_gen)
      assert state.is_drawer == false
      assert state.current_word == nil
      assert state.current_word_display == ""
      assert state.word_length == 0
      assert state.revealed_word == nil
      assert state.word_choices == []
      assert state.watching? == false
      assert component.next_action.name == :mounted
      assert component.next_action.params == %{next: :poll_room, delay: 500}
      assert component.next_page == nil

      html = render_template(state, %{room_id: room.id})
      assert html =~ "game-page-marker"
      assert html =~ "Room #{room.name}"
      refute html =~ "room not found"
    end

    test "a visitor without an account watches and is never the drawer", %{room: room} do
      assert {component, _server} =
               GamePage.init(%{room_id: room.id}, %Hologram.Component{}, anon_server())

      assert component.state.current_user_id == nil
      assert component.state.is_creator == false
      assert component.state.is_drawer == false
      assert component.state.watching? == true
      assert component.next_action.name == :mounted
      assert component.next_action.params == %{next: :do_join_as_watcher, delay: 0}
    end
  end

  # put_page/3 does nothing from init, so these branches must render on their
  # own and leave through the action queued for the mount.
  describe "init/3 for a room that can't be shown" do
    test "an unknown room renders the placeholder and goes home", %{creator: creator} do
      for room_id <- [Ecto.UUID.generate(), "not-a-room-id"],
          server <- [server_for(creator), anon_server()] do
        {component, server} = GamePage.init(%{room_id: room_id}, %Hologram.Component{}, server)

        assert %Hologram.Component{state: state} = component
        assert state == %{room_missing?: true}
        # The user (or nil) is stashed for AppLayout on this branch too.
        assert Map.has_key?(server.stash, :current_user)
        assert component.next_action.name == :go_home
        assert component.next_page == nil
        refute RoomServer.room_exists?(room_id)

        html = render_template(state)
        assert html =~ "room not found"
        refute html =~ "game-page-marker"
      end
    end

    test "a dissolved room is not started again", %{room: room, creator: creator} do
      kill_room!(room)
      {:ok, %{status: :ended}} = Games.dissolve_room(room.id)

      {component, server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(creator))

      assert server.stash.current_user.id == creator.id
      assert component.state == %{room_missing?: true}
      assert component.next_action.name == :go_home
      assert component.next_page == nil
      assert render_template(component.state) =~ "room not found"
      # gen_server unregisters the name before start_child returns the error.
      refute RoomServer.room_exists?(room.id)

      assert RoomServer.ensure_started(room.id) == {:error, :room_ended}
      refute RoomServer.room_exists?(room.id)
    end

    test "a room in its post-game window goes to the score page", ctx do
      %{room: room, creator: creator} = ctx
      {:ok, game} = Games.create_game(room.id, 1)
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
      :sys.replace_state(pid, &%{&1 | status: :post_game, last_game_id: game.id})

      {component, _server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(creator))

      assert component.state.room_missing? == false
      assert component.next_page == nil
      assert component.next_action.name == :go_score
      assert component.next_action.params == %{game_id: game.id}

      result = GamePage.action(:go_score, component.next_action.params, component)

      assert result.next_page == {ScrawlyWeb.Pages.GameScorePage, [game_id: game.id]}
    end
  end

  describe "action/3" do
    test "update_message updates the message" do
      component = %Hologram.Component{state: %{new_message: ""}}
      result = GamePage.action(:update_message, %{event: %{value: "Hello"}}, component)

      assert result.state.new_message == "Hello"
    end

    test "send_message clears input and sends via command" do
      component = %Hologram.Component{
        props: %{room_id: "test-room"},
        state: %{
          new_message: "Test message",
          chat_messages: [],
          current_user_id: "user-1",
          current_user_username: "Alice",
          is_drawer: false,
          correct_guessers: [],
          current_word: nil,
          rate_limited: false,
          message_timestamps: [],
          drawing_path: "",
          drawing?: false,
          drawing_sent_length: 0
        }
      }

      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == ""
      # Messages go to the server via :submit_guess, not added locally
      assert result.state.chat_messages == []
      assert result.next_command.name == :submit_guess
      assert result.next_command.params == %{room_id: "test-room", text: "Test message"}
    end

    test "send_message ignores empty messages" do
      component = %Hologram.Component{
        props: %{room_id: "test-room"},
        state: %{
          new_message: "   ",
          chat_messages: [],
          current_user_id: "user-1",
          current_user_username: "Alice",
          is_drawer: false,
          correct_guessers: [],
          current_word: nil,
          rate_limited: false,
          message_timestamps: [],
          drawing_path: "",
          drawing?: false,
          drawing_sent_length: 0
        }
      }

      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == "   "
      assert length(result.state.chat_messages) == 0
    end

    test "go_home navigates to home page, whatever the state" do
      component = %Hologram.Component{state: %{room_missing?: true}}
      result = GamePage.action(:go_home, %{}, component)

      assert result.next_page == ScrawlyWeb.Pages.HomePage
    end
  end

  # The page template alone (no layout), rendered as the server does on load:
  # its vars are the page params (props) merged with the state.
  defp render_template(state, params \\ %{}) do
    {html, _registry, _server} =
      GamePage.template().(Map.merge(params, state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  # A :room_refreshed payload as RoomServer.View.for_viewer/2 builds it for
  # user-1, a guesser: no word, no choices.
  defp view_params(component, overrides) do
    Map.merge(
      %{
        room_id: component.props.room_id,
        status: :playing,
        players: component.state.players,
        version: 1,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        round_remaining_ms: 80_000,
        round_active: true,
        correct_guessers: [],
        chat_messages: [],
        drawing_strokes: [],
        name: "Test Room",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        past_games: [],
        last_game_id: nil,
        phase: :drawing,
        choice_remaining_ms: 0,
        round_duration: 80,
        choice_duration: 15,
        word_display: "_ _ _ _ _ _ _ _ _",
        word_length: 9,
        revealed_word: nil,
        is_drawer: false,
        drawer_name: "Alice",
        current_word: nil,
        word_choices: []
      },
      overrides
    )
  end

  defp started(component, overrides) do
    state =
      Map.merge(
        component.state,
        %{
          game_started: true,
          game_id: "g1",
          round: 1,
          phase: :drawing,
          room_status: :playing,
          current_drawer: %{id: "user-2", username: "Alice"},
          current_word_display: "_ _ _ _ _ _ _ _ _",
          word_length: 9,
          time_left: 60,
          version: 4
        }
      )

    %{component | state: Map.merge(state, overrides)}
  end

  describe "room_refreshed game transitions" do
    setup %{room: room} do
      players = [
        %{id: "user-1", username: "You", score: 0},
        %{id: "user-2", username: "Alice", score: 0},
        %{id: "user-3", username: "Bob", score: 0}
      ]

      component = %Hologram.Component{
        props: %{room_id: room.id},
        state:
          %{
            room_code: room.code,
            current_user_id: "user-1",
            players: players,
            game_id: nil,
            game_started: false,
            can_start_game: true,
            round: 0,
            total_rounds: 5,
            current_drawer: nil,
            current_word: nil,
            current_word_display: "",
            word_length: 0,
            revealed_word: nil,
            time_left: 0,
            is_drawer: false,
            is_creator: true,
            chat_messages: [],
            new_message: "",
            correct_guessers: [],
            used_words: [],
            rate_limited: false,
            message_timestamps: [],
            watching?: false,
            leaving?: false,
            room_status: :lobby,
            room_name: "Room ABCD",
            current_user_username: "You",
            version: 0,
            phase: :idle,
            word_choices: [],
            choice_time_left: 0,
            past_games: [],
            drawing_strokes: [],
            drawing_path: "",
            drawing?: false,
            drawing_sent_length: 0
          }
          |> Map.merge(countdown_state())
      }

      %{component: component, players: players}
    end

    test "room_refreshed detects game start", %{component: component} do
      result = GamePage.action(:room_refreshed, view_params(component, %{}), component)

      assert result.state.game_started == true
      assert result.state.game_id == "g1"
      assert result.state.round == 1
      assert result.state.current_drawer.id == "user-2"
      assert result.state.current_word_display == "_ _ _ _ _ _ _ _ _"
      assert result.state.word_length == 9
      assert result.state.current_word == nil
      assert result.state.time_left == 80
      assert result.state.is_drawer == false
    end

    test "room_refreshed redirects to score page on game end", %{component: component} do
      started = started(component, %{round: 3, time_left: 20})

      params =
        view_params(component, %{
          status: :lobby,
          version: 10,
          game_id: nil,
          current_round: 0,
          current_drawer_id: nil,
          round_remaining_ms: 0,
          round_active: false,
          phase: :idle,
          word_display: "",
          word_length: 0,
          drawer_name: "Unknown",
          last_game_id: "g1"
        })

      result = GamePage.action(:room_refreshed, params, started)

      assert result.next_page == {ScrawlyWeb.Pages.GameScorePage, [game_id: "g1"]}
    end

    test "room_refreshed re-anchors the countdown and shows the hint", %{component: component} do
      started = started(component, %{})

      params =
        view_params(component, %{
          version: 5,
          round_remaining_ms: 55_000,
          word_display: "b _ _ _ _ _ _ _ _"
        })

      before = System.monotonic_time(:millisecond)
      result = GamePage.action(:room_refreshed, params, started)

      assert result.state.time_left == 55
      assert (result.state.round_deadline_local - before) in 55_000..55_500
      assert result.state.current_word_display == "b _ _ _ _ _ _ _ _"
      assert result.next_action.name == :countdown_tick
    end

    test "room_refreshed keeps local strokes: replies carry none", %{component: component} do
      stroke = %{id: "s-1", path: "M0 0 L1 1", color: "#000000", width: 2}
      started = started(component, %{drawing_strokes: [stroke]})

      result = GamePage.action(:room_refreshed, view_params(component, %{version: 5}), started)

      assert result.state.drawing_strokes == [stroke]
    end

    test "room_refreshed stores the revealed word at :round_end", %{component: component} do
      params =
        view_params(component, %{
          version: 5,
          phase: :round_end,
          round_remaining_ms: 0,
          round_active: false,
          word_display: "b _ _ _ e _ _ _ y",
          revealed_word: "butterfly"
        })

      result = GamePage.action(:room_refreshed, params, started(component, %{}))

      assert result.state.revealed_word == "butterfly"
      assert result.state.phase == :round_end
      assert result.state.current_word == nil
    end
  end

  describe "room_delta word fields" do
    setup %{room: room} do
      component = %Hologram.Component{
        props: %{room_id: room.id},
        state:
          %{
            is_creator: false,
            players: [],
            watchers: [],
            past_games: [],
            correct_guessers: [],
            leaving?: false,
            game_started: true,
            round: 1,
            phase: :drawing,
            version: 4,
            time_left: 60,
            choice_time_left: 0,
            current_word: nil,
            current_word_display: "_ _ _ _ _ _ _ _ _",
            word_length: 9,
            revealed_word: nil
          }
          |> Map.merge(countdown_state())
      }

      delta = %{
        room_id: room.id,
        status: :playing,
        players: [],
        watchers: [],
        version: 5,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        round_remaining_ms: 30_000,
        choice_remaining_ms: 0,
        round_duration: 60,
        choice_duration: 15,
        round_active: true,
        correct_guessers: [],
        phase: :drawing,
        last_game_id: nil,
        max_players: 4,
        past_games: [],
        word_display: "b _ _ _ _ _ _ _ y",
        word_length: 9,
        revealed_word: nil
      }

      %{component: component, delta: delta}
    end

    test "a reveal updates the hint and the countdown without a poll", ctx do
      %{component: component, delta: delta} = ctx
      result = GamePage.action(:room_delta, delta, component)

      assert result.state.current_word_display == "b _ _ _ _ _ _ _ y"
      assert result.state.time_left == 30
      assert result.next_command == nil
    end

    test "never touches the drawer's word", %{component: component, delta: delta} do
      drawer = %{component | state: %{component.state | current_word: "butterfly"}}

      result = GamePage.action(:room_delta, delta, drawer)

      assert result.state.current_word == "butterfly"
    end

    test ":round_end stores the revealed word and polls", %{component: component, delta: delta} do
      ended = %{delta | phase: :round_end, round_remaining_ms: 0, revealed_word: "butterfly"}

      result = GamePage.action(:room_delta, ended, component)

      assert result.state.revealed_word == "butterfly"
      assert result.next_command.name == :poll_room_state
    end

    test "a delta that ends :drawing closes the drawer's canvas before the poll reply", ctx do
      %{component: component, delta: delta} = ctx

      drawer = %{
        component
        | state:
            Map.merge(component.state, %{
              is_drawer: true,
              drawing?: true,
              room_code: "ABCD",
              channel_connected: true
            })
      }

      pointer = %{event: %{offset_x: 10, offset_y: 10}}
      assert GamePage.action(:canvas_pointer_down, pointer, drawer).state.drawing? == true

      ended = %{delta | phase: :round_end, round_remaining_ms: 0, revealed_word: "butterfly"}
      result = GamePage.action(:room_delta, ended, drawer)

      assert result.state.phase == :round_end
      assert result.state.drawing? == false
      assert result.next_command.name == :poll_room_state

      closed = GamePage.action(:canvas_pointer_down, pointer, settled(result))
      assert closed.state.drawing? == false

      # The poll reply then finds the phase already applied.
      reply =
        Map.merge(ended, %{
          is_drawer: true,
          drawer_name: "Alice",
          current_word: "butterfly",
          word_choices: [],
          chat_messages: [],
          drawing_strokes: []
        })

      refreshed = GamePage.action(:room_refreshed, reply, settled(result))
      assert refreshed.state.phase == :round_end
      assert refreshed.state.drawing? == false
    end

    test "other phase changes still wait for the poll reply", ctx do
      %{component: component, delta: delta} = ctx
      choosing = %{delta | phase: :choosing, current_round: 2, round_remaining_ms: 0}

      result = GamePage.action(:room_delta, choosing, component)

      assert result.state.phase == :drawing
      assert result.next_command.name == :poll_room_state
    end

    test "a stale version is ignored", %{component: component, delta: delta} do
      result = GamePage.action(:room_delta, %{delta | version: 4}, component)

      assert result.state == component.state
    end
  end

  # The countdown keys init puts, before :mounted anchors anything.
  defp countdown_state(overrides \\ %{}) do
    Map.merge(
      %{
        round_remaining_ms: 0,
        choice_remaining_ms: 0,
        choice_duration: 15,
        round_duration: 60,
        round_deadline_local: nil,
        choice_deadline_local: nil,
        tick_gen: 7,
        last_tick_at: nil
      },
      overrides
    )
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp put_countdown(component, overrides),
    do: %{component | state: Map.merge(component.state, overrides)}

  # The runtime takes the queued action and command off the component after
  # each action; chained calls in a test must too.
  defp settled(component), do: %{component | next_action: nil, next_command: nil}

  defp assert_tick(result, gen) do
    assert %Hologram.Component.Action{name: :countdown_tick, params: %{gen: ^gen}, delay: delay} =
             result.next_action

    # Always delayed, never more than a second (plus the slack) away.
    assert delay in 1..1_015
    delay
  end

  describe "countdowns" do
    setup %{room: room} do
      component = %Hologram.Component{
        props: %{room_id: room.id},
        state:
          Map.merge(countdown_state(), %{
            is_creator: false,
            players: [],
            watchers: [],
            past_games: [],
            correct_guessers: [],
            leaving?: false,
            game_started: true,
            round: 1,
            phase: :drawing,
            version: 4,
            time_left: 0,
            choice_time_left: 0,
            current_word: nil,
            current_word_display: "_ _ _ _ _",
            word_length: 5,
            revealed_word: nil
          })
      }

      delta = %{
        room_id: room.id,
        status: :playing,
        players: [],
        watchers: [],
        version: 5,
        game_id: "g1",
        current_round: 1,
        total_rounds: 2,
        current_drawer_id: "user-2",
        round_active: true,
        correct_guessers: [],
        phase: :drawing,
        last_game_id: nil,
        max_players: 4,
        past_games: [],
        word_display: "_ _ _ _ _",
        word_length: 5,
        revealed_word: nil,
        round_remaining_ms: 30_000,
        choice_remaining_ms: 0,
        round_duration: 60,
        choice_duration: 15
      }

      %{component: component, delta: delta}
    end

    test ":room_delta anchors the countdown and starts one tick chain", ctx do
      before = now_ms()
      result = GamePage.action(:room_delta, ctx.delta, ctx.component)

      assert (result.state.round_deadline_local - before) in 30_000..30_500
      assert result.state.choice_deadline_local == nil
      assert result.state.time_left == 30
      assert result.state.choice_time_left == 0
      assert result.state.tick_gen == 8
      assert result.state.last_tick_at >= before
      assert result.next_command == nil
      assert_tick(result, 8)

      # Another delta while that chain is alive only re-anchors.
      again =
        GamePage.action(
          :room_delta,
          %{ctx.delta | version: 6, round_remaining_ms: 20_000},
          settled(result)
        )

      assert again.state.time_left == 20
      assert (again.state.round_deadline_local - before) in 20_000..20_500
      assert again.state.tick_gen == 8
      assert again.next_action == nil
    end

    test "a transition delta anchors the new phase and still polls", ctx do
      choosing = %{
        ctx.delta
        | phase: :choosing,
          current_round: 2,
          round_remaining_ms: 0,
          choice_remaining_ms: 14_001
      }

      result = GamePage.action(:room_delta, choosing, ctx.component)

      assert result.state.choice_time_left == 15
      assert result.state.time_left == 0
      assert is_integer(result.state.choice_deadline_local)
      assert result.state.round_deadline_local == nil
      assert result.next_command.name == :poll_room_state
      assert_tick(result, 8)
    end

    test ":countdown_tick recomputes from the anchor and lands after the next second", ctx do
      before = now_ms()

      comp =
        put_countdown(ctx.component, %{
          round_deadline_local: before + 12_300,
          tick_gen: 8,
          last_tick_at: before - 1_000
        })

      result = GamePage.action(:countdown_tick, %{gen: 8}, comp)

      assert result.state.time_left == 13
      assert result.state.last_tick_at >= before
      # 12_300 ms left shows 13 until 12_000: the next tick comes ~300 ms later.
      assert assert_tick(result, 8) in 250..315

      choosing =
        put_countdown(ctx.component, %{
          choice_deadline_local: before + 14_001,
          tick_gen: 8,
          last_tick_at: before - 1_000
        })

      result = GamePage.action(:countdown_tick, %{gen: 8}, choosing)
      assert result.state.choice_time_left == 15
      assert_tick(result, 8)
    end

    test "a stale gen or a page being left does nothing; no deadline ends the chain", ctx do
      alive =
        put_countdown(ctx.component, %{
          round_deadline_local: now_ms() + 10_000,
          tick_gen: 8,
          last_tick_at: now_ms()
        })

      stale = GamePage.action(:countdown_tick, %{gen: 7}, alive)
      assert stale.state == alive.state
      assert stale.next_action == nil

      leaving = put_countdown(alive, %{leaving?: true})
      left = GamePage.action(:countdown_tick, %{gen: 8}, leaving)
      assert left.state == leaving.state
      assert left.next_action == nil

      idle = put_countdown(alive, %{round_deadline_local: nil})
      ended = GamePage.action(:countdown_tick, %{gen: 8}, idle)
      assert ended.state.last_tick_at == nil
      assert ended.next_action == nil
    end

    test "at 0 it clamps and waits; the room's next delta starts a new chain", ctx do
      comp =
        put_countdown(ctx.component, %{
          round_deadline_local: now_ms() - 5,
          tick_gen: 8,
          last_tick_at: now_ms() - 1_000,
          time_left: 1
        })

      result = GamePage.action(:countdown_tick, %{gen: 8}, comp)

      assert result.state.time_left == 0
      assert result.state.round_deadline_local == nil
      assert result.state.last_tick_at == nil
      assert result.next_action == nil

      round_end = %{ctx.delta | version: 6, phase: :round_end, round_remaining_ms: 0}
      ended = GamePage.action(:room_delta, round_end, settled(result))
      assert ended.state.time_left == 0
      assert ended.next_action == nil

      choosing = %{
        ctx.delta
        | version: 7,
          phase: :choosing,
          current_round: 2,
          round_remaining_ms: 0,
          choice_remaining_ms: 15_000
      }

      next = GamePage.action(:room_delta, choosing, settled(ended))
      assert next.state.choice_time_left == 15
      assert_tick(next, 9)
    end

    test "a chain silent for 1.5 s is gone: a delta starts a new one, old ticks drop", ctx do
      quiet =
        put_countdown(ctx.component, %{
          round_deadline_local: now_ms() + 40_000,
          tick_gen: 8,
          last_tick_at: now_ms() - 5_000
        })

      result = GamePage.action(:room_delta, ctx.delta, quiet)
      assert_tick(result, 9)

      late = GamePage.action(:countdown_tick, %{gen: 8}, settled(result))
      assert late.state == result.state
      assert late.next_action == nil

      # A last_tick_at from another document's clock (snapshot restore).
      restored = put_countdown(quiet, %{last_tick_at: now_ms() + 60_000})
      assert_tick(GamePage.action(:room_delta, ctx.delta, restored), 9)
    end
  end

  describe ":choose_word" do
    test "sends only the room and the word" do
      component = %Hologram.Component{
        props: %{room_id: "r1"},
        state: %{is_drawer: true, phase: :choosing, current_user_id: "user-1"}
      }

      result = GamePage.action(:choose_word, %{word: "apple"}, component)

      assert result.next_command.name == :choose_word
      assert result.next_command.params == %{room_id: "r1", word: "apple"}
    end
  end
end
