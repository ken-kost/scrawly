defmodule ScrawlyWeb.Pages.GamePageTest do
  @moduledoc """
  GamePage is push-only: init's state is a full snapshot of the room with its
  `seq`, and from then on the page only applies what the room pushes on
  `{:room, room_id}` (sequenced, with the gap rule) and on the session user's
  own `{:room_player, room_id, user_id}` channel (the drawer's private slice),
  plus `:room_resynced` snapshots it asks for.

  Payloads are built with the real projections (`RoomServer.View`) over a
  hand-built `%RoomServer{}`.
  """
  # Shared sandbox: init/3 starts a RoomServer process that reads the DB.
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.JsCallTrace, only: [js_calls: 1, js_call_names: 1]

  alias Hologram.Template.Renderer
  alias Scrawly.Games
  alias Scrawly.Games.RoomServer
  alias Scrawly.Games.RoomServer.View
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @me "user-1"
  @drawer "user-2"
  @players [
    %{id: @me, username: "You", score: 0},
    %{id: @drawer, username: "Alice", score: 0},
    %{id: "user-3", username: "Bob", score: 0}
  ]
  @stroke %{id: "s-1", path: "M0 0 L1 1", color: "#000000", width: 2}
  # A drawer's choices as the room sends them (GameFlow.choice/0).
  @two_choices [%{text: "apple", difficulty: :easy}, %{text: "pear", difficulty: :medium}]

  setup do
    creator = create_user()
    room = start_room(creator)

    %{room: room, creator: creator}
  end

  defp channels(server), do: server.subscriptions |> Enum.map(&elem(&1, 0)) |> Enum.sort()

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
      # The name alone: the template adds "room ·" where it wants it.
      assert state.room_name == room.name
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
      # A full snapshot: the room's seq, its chat and its strokes.
      seq = room_state!(room.id).seq
      assert state.last_seq == seq
      assert state.delta_seq == seq
      assert state.strokes_seq == seq
      assert state.chat_messages == []
      assert state.drawing_strokes == []
      assert state.page_shown? == false
      assert is_integer(state.mount_id)
      # A member: nothing to join, no poll.
      assert component.next_action.name == :mounted
      assert component.next_action.params == %{join: nil}
      assert component.next_command == nil
      assert component.next_page == nil
      # The room's channel and the user's own private one.
      assert channels(server) == [{:room, room.id}, {:room_player, room.id, creator.id}]

      html = render_template(state, %{room_id: room.id})
      assert html =~ "game-page-marker"
      assert html =~ ~s|Hologram.dispatchAction("page_shown", "page"|
      assert html =~ Integer.to_string(state.mount_id)
      # The marker carries the instance (drawing_manager.mjs pages its op queue).
      assert html =~ ~s|data-mount="#{state.mount_id}"|
      assert html =~ "room · #{room.name}"
      assert html =~ ~s|<h1 class="lobby-title">#{room.name}</h1>|
      refute html =~ "Room #{room.name}"
      refute html =~ "room not found"
    end

    test "a visitor without an account watches, is never the drawer, has no private channel",
         %{room: room} do
      assert {component, server} =
               GamePage.init(%{room_id: room.id}, %Hologram.Component{}, anon_server())

      assert component.state.current_user_id == nil
      assert component.state.is_creator == false
      assert component.state.is_drawer == false
      assert component.state.watching? == true
      assert component.next_action.name == :mounted
      assert component.next_action.params == %{join: :watcher}
      assert channels(server) == [{:room, room.id}]
    end

    test "a new player joins from :mounted; one already watching joins nothing", %{room: room} do
      player = create_user()

      {component, _server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(player))

      assert component.next_action.params == %{join: :player}

      {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: player.id, username: player.username})

      {watching, _server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(player))

      assert watching.state.watching? == true
      assert watching.next_action.params == %{join: nil}
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
        assert %{room_missing?: true, page_shown?: false, mount_id: mount_id} = state
        assert map_size(state) == 3
        assert is_integer(mount_id)
        # The user (or nil) is stashed for AppLayout on this branch too.
        assert Map.has_key?(server.stash, :current_user)
        assert server.subscriptions == []
        assert component.next_action.name == :go_home
        assert component.next_page == nil
        refute RoomServer.room_exists?(room_id)

        html = render_template(state)
        assert html =~ "room not found"
        refute html =~ "game-page-marker"
        # Its own page_shown script: a Back/Forward restore goes home again.
        assert html =~ ~s(dispatchAction("page_shown")
      end
    end

    test "the placeholder goes home again when Back/Forward restores it" do
      placeholder = %Hologram.Component{
        props: %{room_id: "r1"},
        state: %{room_missing?: true, page_shown?: false, mount_id: 7}
      }

      first = GamePage.action(:page_shown, %{mount_id: "7"}, placeholder)
      assert first.state.page_shown? == true
      assert first.next_action == nil

      again = GamePage.action(:page_shown, %{mount_id: "7"}, first)
      assert again.next_action.name == :go_home
      assert GamePage.action(:go_home, %{}, again).next_page == ScrawlyWeb.Pages.HomePage
    end

    test "a dissolved room is not started again", %{room: room, creator: creator} do
      kill_room!(room)
      {:ok, %{status: :ended}} = Games.dissolve_room(room.id)

      {component, server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(creator))

      assert server.stash.current_user.id == creator.id
      assert %{room_missing?: true, page_shown?: false} = component.state
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
      component = page(new_message: "Test message")

      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == ""
      # Messages go to the server via :submit_guess, not added locally
      assert result.state.chat_messages == []
      assert result.next_command.name == :submit_guess
      assert result.next_command.params == %{room_id: "r1", text: "Test message"}
    end

    test "send_message ignores empty messages" do
      component = page(new_message: "   ")

      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == "   "
      assert result.state.chat_messages == []
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

  # ── Fixtures ─────────────────────────────────────────────────────────

  # What init puts for @me, a guesser, in a lobby whose last broadcast was
  # seq 10 (no chain, no anchors yet).
  defp page(overrides \\ []) do
    state =
      Map.merge(
        %{
          room_missing?: false,
          watching?: false,
          room_code: "ABCD",
          room_name: "Room Test",
          room_status: :lobby,
          players: @players,
          max_players: 4,
          is_creator: true,
          creator_id: @me,
          last_seq: 10,
          delta_seq: 10,
          strokes_seq: 10,
          pending_private: nil,
          resync_requested_at: nil,
          resync_owed_seq: nil,
          stuck_seq: nil,
          phase_entered_at: nil,
          mount_id: 1,
          page_shown?: true,
          restoring?: false,
          current_user_id: @me,
          current_user_username: "You",
          new_message: "",
          rate_limited: false,
          message_timestamps: [],
          game_id: "",
          game_started: false,
          round: 0,
          total_rounds: 3,
          round_remaining_ms: 0,
          choice_remaining_ms: 0,
          choice_duration: 15,
          time_left: 0,
          choice_time_left: 0,
          round_deadline_local: nil,
          choice_deadline_local: nil,
          tick_gen: 7,
          last_tick_at: nil,
          zero_since: nil,
          current_drawer: nil,
          current_word: nil,
          current_word_display: "",
          word_length: 0,
          revealed_word: nil,
          is_drawer: false,
          correct_guessers: [],
          phase: :idle,
          word_choices: [],
          can_start_game: true,
          chat_messages: [],
          drawing_strokes: [],
          draw_tool: %{tool: :brush, color: "#0a0a0a", size: 2},
          leaving?: false,
          watchers: [],
          round_duration: 60,
          socket_token: "",
          channel_connected: false,
          channel_connecting: false,
          past_games: []
        },
        Map.new(overrides)
      )

    %Hologram.Component{props: %{room_id: "r1"}, state: state}
  end

  # The same page in round `round` of game g1, @drawer drawing.
  defp playing(overrides \\ []) do
    page(
      Keyword.merge(
        [
          room_status: :playing,
          game_id: "g1",
          game_started: true,
          round: 1,
          phase: :drawing,
          current_drawer: %{id: @drawer, username: "Alice"},
          current_word_display: "_ _ _ _ _",
          word_length: 5,
          can_start_game: false
        ],
        overrides
      )
    )
  end

  # A room in round 1 of game g1, @drawer drawing "zzyzx" with 30 s left.
  defp room(attrs) do
    now = System.monotonic_time(:millisecond)

    struct!(
      %RoomServer{
        room_id: "r1",
        name: "Test",
        code: "ABCD",
        status: :playing,
        creator_id: @me,
        max_players: 4,
        players: @players,
        seq: 10,
        game_id: "g1",
        current_round: 1,
        total_rounds: 3,
        current_drawer_id: @drawer,
        current_word: "zzyzx",
        phase: :drawing,
        round_active: true,
        round_deadline: now + 30_000
      },
      attrs
    )
  end

  defp delta(seq, attrs \\ []), do: room(attrs) |> View.delta() |> Map.put(:seq, seq)
  defp snapshot(viewer, attrs), do: room(attrs) |> View.for_viewer(viewer)

  defp choosing(round, seq, attrs \\ []) do
    delta(
      seq,
      Keyword.merge(
        [
          current_round: round,
          phase: :choosing,
          current_word: nil,
          round_deadline: nil,
          choice_deadline: System.monotonic_time(:millisecond) + 15_000,
          word_choices: @two_choices
        ],
        attrs
      )
    )
  end

  defp slice(round, attrs \\ []) do
    Map.merge(
      %{
        game_id: "g1",
        round: round,
        phase: :choosing,
        current_word: nil,
        word_choices: @two_choices
      },
      Map.new(attrs)
    )
  end

  defp chat(id, text),
    do: %{id: id, message: text, player_name: "System", type: :system, timestamp: 1}

  # The runtime takes the queued action and command off the component after
  # each action; chained calls in a test must too.
  defp settled(component), do: %{component | next_action: nil, next_command: nil}

  defp assert_resync(result, resubscribe \\ false) do
    assert result.next_command.name == :resync_room
    assert result.next_command.params == %{room_id: "r1", resubscribe: resubscribe}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ── The reducer: game transitions ───────────────────────────────────

  describe "game transitions from :room_delta" do
    test "game start: round, drawer, word fields, countdown; no word for a guesser" do
      {result, calls} =
        js_calls(fn ->
          GamePage.action(:room_delta, choosing(1, 11), page(drawing_strokes: [@stroke]))
        end)

      assert result.state.game_started == true
      assert result.state.game_id == "g1"
      assert result.state.round == 1
      assert result.state.phase == :choosing
      assert result.state.room_status == :playing
      # Name and avatar for the canvas header (the player's own avatar, the
      # default when the player list doesn't carry one).
      assert result.state.current_drawer == %{
               id: @drawer,
               username: "Alice",
               avatar_id: "a-mushroom",
               avatar_color: "3"
             }

      assert result.state.is_drawer == false
      assert result.state.can_start_game == false
      assert result.state.current_word == nil
      assert result.state.word_choices == []
      assert result.state.choice_time_left == 15
      assert result.state.drawing_strokes == []
      assert result.state.last_seq == 11
      assert {:setDrawingPath, [""]} in calls
      assert result.next_command == nil
      assert result.next_action.name == :countdown_tick
    end

    test "the next round resets the canvas and the drawer's word" do
      drawer =
        playing(
          is_drawer: true,
          current_word: "zzyzx",
          current_drawer: %{id: @me, username: "You"}
        )

      {result, names} =
        js_call_names(fn -> GamePage.action(:room_delta, choosing(2, 11), drawer) end)

      assert result.state.round == 2
      assert result.state.is_drawer == false
      assert result.state.current_word == nil
      assert result.state.word_choices == []
      assert result.state.strokes_seq == 11
      assert :setDrawingPath in names
    end

    test "a hint delta re-anchors the countdown and shows the hint" do
      before = now_ms()
      hint = delta(11, hint_stage: 1)

      {result, names} = js_call_names(fn -> GamePage.action(:room_delta, hint, playing()) end)

      assert result.state.current_word_display == hint.word_display
      assert result.state.current_word_display =~ ~r/[a-z]/
      assert result.state.time_left == 30
      assert (result.state.round_deadline_local - before) in 29_500..30_500
      assert result.next_command == nil
      assert result.next_action.name == :countdown_tick
      refute :setDrawingPath in names
    end

    test ":round_end shows the revealed word and closes the drawer's canvas at once" do
      drawer =
        playing(
          is_drawer: true,
          current_word: "zzyzx",
          current_drawer: %{id: @me, username: "You"}
        )

      ended = delta(11, phase: :round_end, current_drawer_id: @me, round_deadline: nil)

      {result, calls} = js_calls(fn -> GamePage.action(:room_delta, ended, drawer) end)

      assert result.state.phase == :round_end
      assert result.state.revealed_word == "zzyzx"
      assert result.state.current_word == "zzyzx"
      assert {:endDrawingPhase, []} in calls
      assert {:setDrawingEnabled, [false]} in calls
      refute Enum.any?(calls, &match?({:setDrawingPath, _}, &1))
      assert GamePage.can_draw?(settled(result).state) == false
    end

    test "the post_game delta goes to the score page and stops acting on the page" do
      over = delta(11, status: :post_game, game_id: nil, last_game_id: "g1", phase: :idle)

      result = GamePage.action(:room_delta, over, playing())

      assert result.next_page == {ScrawlyWeb.Pages.GameScorePage, [game_id: "g1"]}
      assert result.state.leaving? == true
      assert GamePage.action(:room_delta, delta(12), settled(result)) == settled(result)
    end

    test "a lobby delta after a game (post_game missed) ends the game on the page" do
      lobby =
        delta(11,
          status: :lobby,
          game_id: nil,
          current_round: 0,
          current_drawer_id: nil,
          phase: :idle,
          last_game_id: "g1"
        )

      {result, names} =
        js_call_names(fn ->
          GamePage.action(:room_delta, lobby, playing(drawing_strokes: [@stroke]))
        end)

      assert result.state.game_started == false
      assert result.state.game_id == ""
      assert result.state.current_drawer == nil
      assert result.state.drawing_strokes == []
      assert result.state.can_start_game == true
      assert :setDrawingPath in names
      # Leaves through the gap rule only (seq 11 follows 10): no resync.
      assert result.next_command == nil
    end

    test "an ended room goes home after a moment" do
      result = GamePage.action(:room_delta, delta(11, status: :ended, players: []), playing())

      assert result.state.room_status == :ended
      assert %Hologram.Component.Action{name: :go_home, delay: 2_000} = result.next_action
    end

    test "is_drawer needs a session user equal to the drawer" do
      no_drawer = delta(11, current_drawer_id: nil, phase: :idle)
      anon = page(current_user_id: nil)

      assert GamePage.action(:room_delta, no_drawer, anon).state.is_drawer == false

      assert GamePage.action(:room_delta, delta(11, current_drawer_id: @me), page()).state.is_drawer
    end
  end

  # ── Sequencing ──────────────────────────────────────────────────────

  @sequenced [
    room_delta: &__MODULE__.delta_params/1,
    chat_appended: &__MODULE__.chat_params/1,
    stroke_completed: &__MODULE__.stroke_params/1,
    drawing_cleared: &__MODULE__.cleared_params/1,
    drawing_undone: &__MODULE__.undone_params/1
  ]

  def delta_params(seq), do: delta(seq)
  def chat_params(seq), do: %{message: chat(seq, "TEST line #{seq}"), seq: seq}

  def stroke_params(seq),
    do: %{stroke_id: "s-#{seq}", path: "M 1 1", color: "#000000", width: 2, seq: seq}

  def cleared_params(seq), do: %{seq: seq}
  def undone_params(seq), do: %{stroke_id: "s-1", seq: seq}

  describe "the gap rule" do
    test "seq <= last_seq leaves the page unchanged, for every {:room} action" do
      component = playing(drawing_strokes: [@stroke], chat_messages: [chat(9, "old")])

      for {action, params} <- @sequenced, seq <- [9, 10] do
        assert GamePage.action(action, params.(seq), component) == component,
               "#{action} with seq #{seq} changed the page"
      end
    end

    test "nothing is applied while the page is being left" do
      leaving = playing(leaving?: true)

      for {action, params} <- @sequenced do
        assert GamePage.action(action, params.(11), leaving) == leaving
      end
    end

    test "seq == last_seq + 1 is applied with no request" do
      component = playing()

      for {action, params} <- @sequenced do
        result = GamePage.action(action, params.(11), component)
        assert result.state.last_seq == 11, "#{action} did not advance last_seq"
        assert result.next_command == nil
      end
    end

    test "a gap is applied, then queues exactly one :resync_room; a second gap within 5 s queues none" do
      component = playing()

      for {action, params} <- @sequenced do
        first = GamePage.action(action, params.(13), component)
        assert first.state.last_seq == 13
        assert_resync(first)
        assert is_integer(first.state.resync_requested_at)
        assert first.state.resync_owed_seq == 12

        second = GamePage.action(action, params.(16), settled(first))
        assert second.state.last_seq == 16
        assert second.next_command == nil, "#{action} queued a second resync"
        assert second.state.resync_owed_seq == 15
      end

      # The applied part of the gapped action is there.
      chat = GamePage.action(:chat_appended, chat_params(13), component)
      assert [%{id: 13}] = chat.state.chat_messages
    end

    test "an unanswered resync may be retried after 5 s" do
      waited = playing(resync_requested_at: now_ms() - 5_001)
      assert_resync(GamePage.action(:chat_appended, chat_params(13), waited))

      # A timestamp from another document's clock (a restored snapshot).
      restored = playing(resync_requested_at: now_ms() + 60_000)
      assert_resync(GamePage.action(:chat_appended, chat_params(13), restored))
    end

    test "other command replies carry no seq and never move last_seq" do
      component =
        playing(is_drawer: true, phase: :choosing, current_drawer: %{id: @me, username: "You"})

      for {action, params} <- [
            stroke_op_acked: %{op_seq: 3},
            guess_result: %{outcome: :chat},
            private_state: slice(1)
          ] do
        assert GamePage.action(action, params, component).state.last_seq == 10
      end
    end
  end

  # ── The drawer's private slice ──────────────────────────────────────

  # QA G9: a lobby player the room dropped (no open tab for a while, or a
  # leave from another tab) is told so and offered to join again.
  describe "dropped from the lobby" do
    @others Enum.reject(@players, &(&1.id == @me))
    # What the lobby template reads beyond page/1.
    @lobby_keys [
      is_creator: false,
      creator_id: @drawer,
      join_notice: nil,
      word_source: :local,
      themes: [],
      answer_kind: :mixed,
      round_multiplier: 1,
      prompt: "",
      creator_name: "Alice",
      ai_tone: :fun,
      chat_notice: nil,
      chat_notice_gen: 0,
      invite_copy: :idle,
      invite_copy_gen: 0,
      invite_link: nil,
      show_room_settings: false,
      room_settings_form: 0,
      room_settings_initial: %{},
      saving_room_settings?: false,
      room_settings_attempt: 0,
      room_settings_errors: %{}
    ]

    defp lobby_delta(seq, players),
      do:
        delta(seq,
          status: :lobby,
          game_id: nil,
          current_round: 0,
          current_drawer_id: nil,
          current_word: nil,
          phase: :idle,
          round_active: false,
          round_deadline: nil,
          players: players
        )

    test "says so and offers a join button" do
      component = page(@lobby_keys)
      result = GamePage.action(:room_delta, lobby_delta(11, @others), component)

      assert result.state.join_notice =~ "no longer in this room"

      html = render_template(result.state, %{room_id: "r1"})
      assert html =~ "no longer in this room"
      assert html =~ ~r/<button[^>]*>\s*join\s*<\/button>/
    end

    test "joining again clears it; leaving from this tab never shows it" do
      component = page(@lobby_keys)
      dropped = GamePage.action(:room_delta, lobby_delta(11, @others), component)

      back = GamePage.action(:room_delta, lobby_delta(12, @players), dropped)
      assert back.state.join_notice == nil

      refute render_template(back.state, %{room_id: "r1"}) =~
               ~r/<button[^>]*>\s*join\s*<\/button>/

      leaving = page(Keyword.put(@lobby_keys, :leaving?, true))
      left = GamePage.action(:room_delta, lobby_delta(11, @others), leaving)
      assert left == leaving or left.state.join_notice == nil
    end
  end

  # QA G14: the room publishes only the undone stroke's id.
  describe ":drawing_undone" do
    test "a viewer removes that stroke by id and keeps the rest, live overlays included" do
      s2 = %{@stroke | id: "s-2"}
      component = playing(drawing_strokes: [@stroke, s2])

      {result, calls} =
        js_calls(fn ->
          GamePage.action(:drawing_undone, %{stroke_id: "s-1", seq: 11}, component)
        end)

      assert result.state.drawing_strokes == [s2]
      assert result.state.strokes_seq == 11
      assert result.state.last_seq == 11
      assert calls == []
    end

    test "an id the viewer doesn't hold changes no stroke" do
      component = playing(drawing_strokes: [@stroke])
      result = GamePage.action(:drawing_undone, %{stroke_id: "s-other", seq: 11}, component)

      assert result.state.drawing_strokes == [@stroke]
      assert result.state.last_seq == 11
    end

    test "the drawer's tabs keep their own canvas; another tab's undo leaves it too" do
      drawer = playing(current_user_id: @drawer, is_drawer: true, drawing_strokes: [@stroke])

      {result, calls} =
        js_calls(fn -> GamePage.action(:drawing_undone, %{stroke_id: "s-1", seq: 11}, drawer) end)

      assert result.state.drawing_strokes == [@stroke]
      # drawing_manager.mjs drops it only if this tab still holds it (another
      # of the drawer's tabs undid it).
      assert calls == [forgetStroke: ["s-1"]]
    end

    test "a stale snapshot can't bring the undone stroke back" do
      s2 = %{@stroke | id: "s-2"}

      undone =
        GamePage.action(
          :drawing_undone,
          %{stroke_id: "s-1", seq: 11},
          playing(drawing_strokes: [@stroke, s2])
        )

      view = snapshot(@me, seq: 10, phase: :drawing, drawing_strokes: [@stroke, s2])
      result = GamePage.action(:room_resynced, view, undone)

      assert result.state.drawing_strokes == [s2]
    end
  end

  describe ":private_state" do
    test "the first drawer of a new game sees the choices as soon as the slice follows the delta" do
      lobby = page()
      started = GamePage.action(:room_delta, choosing(1, 11, current_drawer_id: @me), lobby)

      assert started.state.is_drawer == true
      assert started.state.word_choices == []

      result = GamePage.action(:private_state, slice(1), settled(started))
      assert result.state.word_choices == @two_choices
      assert result.state.last_seq == 11
    end

    test "a slice for an earlier round is ignored" do
      drawer = playing(round: 2, phase: :choosing, is_drawer: true)
      assert GamePage.action(:private_state, slice(1), drawer) == drawer
    end

    test "a round n+1 slice that arrives early is applied when the round n+1 delta arrives" do
      component = playing(round: 1)

      held = GamePage.action(:private_state, slice(2), component)
      assert held.state.pending_private == slice(2)
      assert held.state.word_choices == []

      result =
        GamePage.action(:room_delta, choosing(2, 11, current_drawer_id: @me), settled(held))

      assert result.state.round == 2
      assert result.state.is_drawer == true
      assert result.state.word_choices == @two_choices
      assert result.state.pending_private == nil
    end

    test "a slice for a game the page has not seen yet waits for its delta" do
      held = GamePage.action(:private_state, slice(1), page())
      assert held.state.pending_private == slice(1)

      result =
        GamePage.action(:room_delta, choosing(1, 11, current_drawer_id: @me), settled(held))

      assert result.state.word_choices == @two_choices
    end

    test "a held slice for a round the page has passed is dropped" do
      component = playing(round: 1, pending_private: slice(2))
      result = GamePage.action(:room_delta, choosing(3, 11), component)
      assert result.state.pending_private == nil
      assert result.state.word_choices == []
    end

    test "the choose_word reply shows the word before the :drawing delta, and a late :choosing slice can't undo it" do
      drawer =
        playing(
          phase: :choosing,
          is_drawer: true,
          word_choices: [%{text: "zzyzx", difficulty: :easy}, %{text: "pear", difficulty: nil}]
        )

      committed = slice(1, phase: :drawing, current_word: "zzyzx", word_choices: [])

      result = GamePage.action(:private_state, committed, drawer)
      assert result.state.current_word == "zzyzx"
      assert result.state.phase == :choosing

      drawing = GamePage.action(:room_delta, delta(11, current_drawer_id: @me), settled(result))
      assert drawing.state.phase == :drawing
      assert drawing.state.current_word == "zzyzx"

      assert GamePage.action(:private_state, slice(1), settled(drawing)).state.current_word ==
               "zzyzx"
    end

    test "a drawer whose slice never came resyncs from the countdown, once per seq" do
      deadline = now_ms() + 10_000

      lost =
        playing(
          phase: :choosing,
          is_drawer: true,
          current_drawer: %{id: @me, username: "You"},
          choice_deadline_local: deadline,
          tick_gen: 8,
          phase_entered_at: now_ms() - 2_000
        )

      result = GamePage.action(:countdown_tick, %{gen: 8}, lost)
      assert_resync(result)
      assert result.state.stuck_seq == 10
      assert result.next_action.name == :countdown_tick

      again =
        GamePage.action(
          :countdown_tick,
          %{gen: 8},
          settled(%{result | state: %{result.state | resync_requested_at: nil}})
        )

      assert again.next_command == nil

      # Not before the slice had its chance to arrive.
      fresh = %{lost | state: %{lost.state | phase_entered_at: now_ms()}}
      assert GamePage.action(:countdown_tick, %{gen: 8}, fresh).next_command == nil

      # A drawer with a word, or a guesser, never asks.
      with_word = %{
        lost
        | state: %{
            lost.state
            | phase: :drawing,
              current_word: "zzyzx",
              round_deadline_local: deadline
          }
      }

      assert GamePage.action(:countdown_tick, %{gen: 8}, with_word).next_command == nil
      guesser = %{lost | state: %{lost.state | is_drawer: false}}
      assert GamePage.action(:countdown_tick, %{gen: 8}, guesser).next_command == nil
    end
  end

  # ── Snapshots ───────────────────────────────────────────────────────

  describe ":room_resynced" do
    test "after ~10 s offline a viewer recovers players, phase, countdown, chat and canvas" do
      offline = playing(chat_messages: [chat(9, "old")], drawing_strokes: [@stroke])

      # Broadcasts 11..15 were lost; 16 arrives: applied, and a resync goes out.
      gapped = GamePage.action(:chat_appended, chat_params(16), offline)
      assert_resync(gapped)

      strokes = [@stroke, %{@stroke | id: "s-2"}]
      players = Enum.map(@players, &%{&1 | score: 50})
      lines = [chat(16, "TEST line 16"), chat(14, "missed"), chat(9, "old")]

      view =
        snapshot(@me,
          seq: 16,
          players: players,
          current_round: 2,
          phase: :drawing,
          chat_messages: lines,
          drawing_strokes: strokes
        )

      {result, calls} = js_calls(fn -> GamePage.action(:room_resynced, view, settled(gapped)) end)

      assert result.state.last_seq == 16
      assert result.state.players == players
      assert result.state.round == 2
      assert result.state.phase == :drawing
      assert result.state.time_left == 30
      assert is_integer(result.state.round_deadline_local)
      assert result.state.chat_messages == lines
      assert result.state.drawing_strokes == strokes
      assert result.state.resync_requested_at == nil
      assert result.state.resync_owed_seq == nil
      assert {:settleRemoteStrokes, [["s-1", "s-2"]]} in calls
      assert result.next_command == nil
    end

    test "the drawer's canvas stays intact: non-canvas state only" do
      drawer =
        playing(
          is_drawer: true,
          current_word: "zzyzx",
          current_drawer: %{id: @me, username: "You"},
          drawing_strokes: [@stroke]
        )

      view =
        snapshot(@me,
          seq: 12,
          current_drawer_id: @me,
          drawing_strokes: [%{@stroke | id: "s-room"}],
          chat_messages: [chat(12, "new")]
        )

      {result, names} = js_call_names(fn -> GamePage.action(:room_resynced, view, drawer) end)

      assert result.state.chat_messages == [chat(12, "new")]
      assert result.state.current_word == "zzyzx"
      assert result.state.drawing_strokes == [@stroke]

      for name <- [:setStrokes, :setDrawingPath, :restoreStrokes, :mountCanvas] do
        refute name in names, "#{name} touched the drawer's canvas"
      end
    end

    test "a snapshot older than broadcasts already applied keeps what is newer" do
      # The resync reply was overtaken: 13 and 14 came first.
      component =
        playing(
          last_seq: 14,
          delta_seq: 13,
          strokes_seq: 10,
          players: [hd(@players)],
          chat_messages: [chat(14, "after"), chat(9, "old")],
          drawing_strokes: [%{@stroke | id: "s-12"}, Map.put(%{@stroke | id: "s-late"}, :seq, 12)]
        )

      view =
        snapshot(@me,
          seq: 12,
          chat_messages: [chat(12, "missed"), chat(9, "old")],
          drawing_strokes: [@stroke, %{@stroke | id: "s-12"}]
        )

      result = GamePage.action(:room_resynced, view, component)

      assert result.state.last_seq == 14
      assert result.state.chat_messages == [chat(14, "after"), chat(12, "missed"), chat(9, "old")]
      # The room state of delta 13 is newer than the snapshot's.
      assert result.state.players == [hd(@players)]
      # The snapshot's strokes, plus the one that arrived after it (seq 12 is
      # not after 12: the snapshot has it).
      assert Enum.map(result.state.drawing_strokes, & &1.id) == ["s-1", "s-12"]

      after_it =
        put_in(component.state.drawing_strokes, [Map.put(%{@stroke | id: "s-13"}, :seq, 13)])

      merged = GamePage.action(:room_resynced, view, after_it)
      assert Enum.map(merged.state.drawing_strokes, & &1.id) == ["s-1", "s-12", "s-13"]

      replaced = put_in(component.state.strokes_seq, 13)
      kept = GamePage.action(:room_resynced, view, replaced)
      assert kept.state.drawing_strokes == replaced.state.drawing_strokes
    end

    test "a gap seen while the resync was in flight gets a new one unless the reply covers it" do
      owed = playing(resync_requested_at: now_ms(), resync_owed_seq: 15)

      covered = GamePage.action(:room_resynced, snapshot(@me, seq: 15), owed)
      assert covered.next_command == nil
      assert covered.state.resync_owed_seq == nil

      uncovered = GamePage.action(:room_resynced, snapshot(@me, seq: 14), owed)
      assert_resync(uncovered)
    end

    test "the drawer's word and choices in a snapshot are applied" do
      drawer =
        playing(phase: :choosing, is_drawer: true, current_drawer: %{id: @me, username: "You"})

      view =
        snapshot(@me,
          seq: 11,
          phase: :choosing,
          current_drawer_id: @me,
          current_word: nil,
          round_deadline: nil,
          word_choices: @two_choices
        )

      result = GamePage.action(:room_resynced, view, drawer)
      assert result.state.word_choices == @two_choices
    end

    test "a join reply connects the game socket of a new member" do
      newcomer = page(players: [], socket_token: "tok")

      view =
        snapshot(@me, seq: 12, status: :lobby, game_id: nil, phase: :idle, current_drawer_id: nil)

      {result, calls} = js_calls(fn -> GamePage.action(:room_resynced, view, newcomer) end)

      assert {:connectGameChannel, ["tok", "ABCD"]} in calls
      assert result.state.channel_connecting == true

      {_again, again_calls} =
        js_calls(fn -> GamePage.action(:room_resynced, view, settled(result)) end)

      refute Enum.any?(again_calls, &(elem(&1, 0) == :connectGameChannel))
    end
  end

  # ── Back/Forward ────────────────────────────────────────────────────

  describe ":page_shown" do
    test "the first one only marks the page shown" do
      fresh = page(page_shown?: false)
      result = GamePage.action(:page_shown, %{mount_id: "1"}, fresh)

      assert result.state.page_shown? == true
      assert result.next_command == nil
      assert result.next_action == nil
    end

    test "again (a Back/Forward restore) resyncs and resubscribes; the reply rebuilds the canvas" do
      restored =
        playing(
          is_drawer: true,
          current_drawer: %{id: @me, username: "You"},
          current_word: "zzyzx",
          last_tick_at: now_ms(),
          resync_requested_at: now_ms(),
          socket_token: "tok",
          channel_connected: true
        )

      {shown, shown_calls} =
        js_calls(fn -> GamePage.action(:page_shown, %{mount_id: "1"}, restored) end)

      assert_resync(shown, true)
      # The canvas belongs to this instance again (its queued ops resume),
      # with the tool the restored toolbar shows; the other rooms' channels
      # the tab may hold go with the resync.
      assert [
               {:restoreCanvas, [_mount_id]},
               {:setDrawTool, [%{tool: "brush", color: "#0a0a0a", size: 2}]},
               {:takeStaleRoomChannels, ["r1"]}
             ] = shown_calls

      assert shown.state.restoring? == true
      assert shown.state.last_tick_at == nil

      view = snapshot(@me, seq: 20, current_drawer_id: @me, drawing_strokes: [@stroke])

      {result, calls} = js_calls(fn -> GamePage.action(:room_resynced, view, settled(shown)) end)

      # The drawer's canvas: the room's strokes plus the ops still queued.
      assert {:rebaseCanvas, [[@stroke]]} in calls
      assert {:ensureGameChannel, ["tok", "ABCD"]} in calls
      assert result.state.restoring? == false
      assert result.state.last_seq == 20
      # The tick chain restarts from the snapshot.
      assert result.next_action.name == :countdown_tick
    end

    test "a page that was left through \"leave\" reloads instead" do
      {result, _calls} =
        js_calls(fn -> GamePage.action(:page_shown, %{}, playing(leaving?: true)) end)

      assert result.next_command == nil
    end
  end

  # ── Countdowns ──────────────────────────────────────────────────────

  defp put_countdown(component, overrides),
    do: %{component | state: Map.merge(component.state, Map.new(overrides))}

  defp assert_tick(result, gen) do
    assert %Hologram.Component.Action{name: :countdown_tick, params: %{gen: ^gen}, delay: delay} =
             result.next_action

    # Always delayed, never more than a second (plus the slack) away.
    assert delay in 1..1_015
    delay
  end

  describe "countdowns" do
    test ":room_delta anchors the countdown and starts one tick chain" do
      before = now_ms()
      result = GamePage.action(:room_delta, delta(11), playing())

      assert (result.state.round_deadline_local - before) in 29_500..30_500
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
          delta(12, round_deadline: now_ms() + 20_000),
          settled(result)
        )

      assert again.state.time_left == 20
      assert again.state.tick_gen == 8
      assert again.next_action == nil
    end

    test ":mounted anchors init's countdowns and starts the chain" do
      component = playing(round_remaining_ms: 25_000, page_shown?: false)

      result = GamePage.action(:mounted, %{join: nil}, component)

      assert result.state.time_left == 25
      assert is_integer(result.state.phase_entered_at)
      assert_tick(result, 8)
      assert result.next_command == nil
    end

    test ":countdown_tick recomputes from the anchor and lands after the next second" do
      before = now_ms()

      comp =
        put_countdown(playing(),
          round_deadline_local: before + 12_300,
          tick_gen: 8,
          last_tick_at: before - 1_000
        )

      result = GamePage.action(:countdown_tick, %{gen: 8}, comp)

      assert result.state.time_left == 13
      assert result.state.last_tick_at >= before
      # 12_300 ms left shows 13 until 12_000: the next tick comes ~300 ms later.
      assert assert_tick(result, 8) in 250..315

      # 14_500 ms left shows 15; the margin keeps this stable on a loaded machine.
      choosing =
        put_countdown(playing(phase: :choosing),
          choice_deadline_local: now_ms() + 14_500,
          tick_gen: 8,
          last_tick_at: before - 1_000
        )

      result = GamePage.action(:countdown_tick, %{gen: 8}, choosing)
      assert result.state.choice_time_left == 15
      assert_tick(result, 8)
    end

    test "a stale gen or a page being left does nothing; no deadline ends the chain" do
      alive =
        put_countdown(playing(),
          round_deadline_local: now_ms() + 10_000,
          tick_gen: 8,
          last_tick_at: now_ms()
        )

      stale = GamePage.action(:countdown_tick, %{gen: 7}, alive)
      assert stale.state == alive.state
      assert stale.next_action == nil

      leaving = put_countdown(alive, leaving?: true)
      left = GamePage.action(:countdown_tick, %{gen: 8}, leaving)
      assert left.state == leaving.state
      assert left.next_action == nil

      idle = put_countdown(alive, round_deadline_local: nil)
      ended = GamePage.action(:countdown_tick, %{gen: 8}, idle)
      assert ended.state.last_tick_at == nil
      assert ended.next_action == nil
    end

    test "watchdog: at 0 it keeps ticking; after ~4 s at 0 in the same phase it resyncs once" do
      at_zero =
        put_countdown(playing(),
          round_deadline_local: now_ms() - 5,
          tick_gen: 8,
          last_tick_at: now_ms() - 1_000,
          time_left: 1
        )

      first = GamePage.action(:countdown_tick, %{gen: 8}, at_zero)
      assert first.state.time_left == 0
      assert is_integer(first.state.zero_since)
      assert first.next_command == nil
      assert %Hologram.Component.Action{delay: 1_000} = first.next_action

      waiting =
        GamePage.action(
          :countdown_tick,
          %{gen: 8},
          put_countdown(settled(first), zero_since: now_ms() - 3_000)
        )

      assert waiting.next_command == nil
      assert waiting.next_action.name == :countdown_tick

      stuck =
        GamePage.action(
          :countdown_tick,
          %{gen: 8},
          put_countdown(settled(first), zero_since: now_ms() - 4_000)
        )

      assert_resync(stuck)
      assert stuck.state.stuck_seq == 10
      assert stuck.state.round_deadline_local == nil
      assert stuck.state.last_tick_at == nil
      assert stuck.next_action == nil

      # The resync shows the room really is still there: no second request.
      view = snapshot(@me, seq: 10, round_deadline: now_ms() - 1)
      replied = GamePage.action(:room_resynced, view, settled(stuck))
      assert replied.next_action == nil
      assert replied.next_command == nil
    end

    test "at 0 outside :choosing and :drawing the chain just stops" do
      ended =
        put_countdown(playing(phase: :round_end),
          round_deadline_local: now_ms() - 5,
          tick_gen: 8,
          last_tick_at: now_ms() - 1_000
        )

      result = GamePage.action(:countdown_tick, %{gen: 8}, ended)
      assert result.state.round_deadline_local == nil
      assert result.next_action == nil
      assert result.next_command == nil
    end

    test "a chain silent for 1.5 s is gone: a delta starts a new one, old ticks drop" do
      quiet =
        put_countdown(playing(),
          round_deadline_local: now_ms() + 40_000,
          tick_gen: 8,
          last_tick_at: now_ms() - 5_000
        )

      result = GamePage.action(:room_delta, delta(11), quiet)
      assert_tick(result, 9)

      late = GamePage.action(:countdown_tick, %{gen: 8}, settled(result))
      assert late.state == result.state
      assert late.next_action == nil

      # A last_tick_at from another document's clock (snapshot restore).
      restored = put_countdown(quiet, last_tick_at: now_ms() + 60_000)
      assert_tick(GamePage.action(:room_delta, delta(11), restored), 9)
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

  describe ":command_denied" do
    test "resyncs, at most once while a resync is in flight" do
      result = GamePage.action(:command_denied, %{command: :start_game, reason: :x}, page())
      assert_resync(result)

      again =
        GamePage.action(:command_denied, %{command: :start_game, reason: :x}, settled(result))

      assert again.next_command == nil
    end
  end
end
