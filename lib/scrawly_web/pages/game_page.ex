defmodule ScrawlyWeb.Pages.GamePage do
  # :id_only - stroke and chat commands need only the session user's id, so
  # the middleware runs no users query per command; init loads the record once.
  use ScrawlyWeb.Page, load: :id_only
  use Hologram.JS

  js_import :connectGameChannel, from: "./game_channel.mjs"
  js_import :ensureGameChannel, from: "./game_channel.mjs"
  js_import :disconnectGameChannel, from: "./game_channel.mjs"

  js_import :setDrawingEnabled, from: "./drawing_manager.mjs"
  js_import :clearDrawing, from: "./drawing_manager.mjs"
  js_import :setDrawingPath, from: "./drawing_manager.mjs"
  js_import :setToolColor, from: "./drawing_manager.mjs"
  js_import :setToolWidth, from: "./drawing_manager.mjs"
  js_import :undoStroke, from: "./drawing_manager.mjs"
  js_import :removeRemoteOverlay, from: "./drawing_manager.mjs"
  js_import :settleRemoteStrokes, from: "./drawing_manager.mjs"
  js_import :clearRemoteStrokes, from: "./drawing_manager.mjs"
  js_import :mountCanvas, from: "./drawing_manager.mjs"
  js_import :restoreStrokes, from: "./drawing_manager.mjs"
  js_import :restoreCanvas, from: "./drawing_manager.mjs"
  js_import :rebaseCanvas, from: "./drawing_manager.mjs"
  js_import :adoptStroke, from: "./drawing_manager.mjs"
  js_import :forgetStroke, from: "./drawing_manager.mjs"
  js_import :applyRoomClear, from: "./drawing_manager.mjs"
  js_import :endDrawingPhase, from: "./drawing_manager.mjs"
  js_import :ackStrokeOp, from: "./drawing_manager.mjs"
  js_import :rejectStrokeOp, from: "./drawing_manager.mjs"
  js_import :applyRejectedStrokes, from: "./drawing_manager.mjs"

  js_import :noteRoomChannel, from: "./room_channels.mjs"
  js_import :takeStaleRoomChannels, from: "./room_channels.mjs"

  js_import :copyInviteLink, from: "./room_links.mjs"
  js_import :selectInviteLink, from: "./room_links.mjs"

  route "/game/:room_id"
  param :room_id, :string

  alias ScrawlyWeb.Components.{Avatar, ChatBox, ScoreBoard, DrawingCanvas, RoomSettingsForm}
  alias ScrawlyWeb.{PlayFeedback, RoomSettings}
  alias ScrawlyWeb.Pages.GamePage.Commands
  alias Scrawly.Games.RoomServer

  # Countdown ticks (see "Round and word-choice countdowns" below).
  @tick_ms 1_000
  @tick_alive_ms 1_500
  @tick_slack_ms 15
  # A countdown that sits at 0 this long while the room still shows the phase
  # it counts down means the phase change was lost: resync.
  @watchdog_ms 4_000
  # The drawer's private slice follows the delta that starts the phase; once
  # it is this late, it was lost.
  @slice_grace_ms 1_500
  # At most one resync in flight; a request with no reply after this long may
  # be retried (there is no command-failure callback).
  @resync_guard_ms 5_000
  @max_chat 50
  # A refused game socket asks for a fresh socket token at most this often.
  @token_refresh_ms 30_000
  # A start request with no answer after this long (the AI call's own
  # timeout is 60 s) gives the start button back.
  @start_game_timeout_ms 90_000
  # How long the invite button reads "copied".
  @invite_copied_ms 2_000
  # A settings save with no answer after this long gives the form back.
  @save_settings_timeout_ms 20_000

  @room_commands ~w(resync_room join_room join_as_watcher leave_watcher start_game leave_room
                    submit_guess choose_word complete_stroke clear_drawing_cmd undo_drawing_cmd
                    update_room_settings)a

  # Page state is serialized into the HTML, so it is built from the session
  # user's own view of the room: only the drawer's view carries the word and
  # the word choices, and a player's view carries the word once they have
  # guessed it (RoomServer.View.for_viewer/2).
  #
  # `room_id` is the page param, so it is a prop: actions read
  # `component.props.room_id` and the template `@room_id`. It is never copied
  # into state (a same-named state key would shadow the prop).
  #
  # The session user is loaded once here and stashed for AppLayout's init.
  #
  # The page is push-only (see "Room broadcasts" below): init's view is a
  # full snapshot with the room's seq, and the page subscribes to the room's
  # public channel and to its own user's private one.
  def init(%{room_id: room_id}, component, server) do
    user_id = ScrawlyWeb.Auth.user_id(server)
    user = current_user_or_nil(server)
    server = put_stash(server, :current_user, user)

    case RoomServer.ensure_started(room_id) do
      {:ok, _pid} ->
        case RoomServer.get_view(room_id, user_id) do
          {:ok, rs} ->
            is_creator = user_id == rs.creator_id
            game_active = rs.game_id != nil

            component =
              component
              |> put_state(:room_missing?, false)
              |> put_state(:watching?, false)
              |> put_state(:room_code, rs.code)
              |> put_state(:room_name, rs.name)
              |> put_state(:room_status, rs.status)
              |> put_state(:players, rs.players)
              |> put_state(:max_players, rs.max_players)
              |> put_state(:is_creator, is_creator)
              |> put_state(:creator_id, rs.creator_id)
              # Sequencing: the seq of the last broadcast applied, and of the
              # last room state / full stroke list applied (stale snapshots,
              # see :room_resynced).
              |> put_state(:last_seq, rs.seq)
              |> put_state(:delta_seq, rs.seq)
              |> put_state(:strokes_seq, rs.seq)
              |> put_state(:pending_private, nil)
              |> put_state(:resync_requested_at, nil)
              |> put_state(:resync_owed_seq, nil)
              |> put_state(:stuck_seq, nil)
              |> put_state(:phase_entered_at, nil)
              # Stable for this page instance: makes the template's inline
              # script unique, so it runs once per page shown (:page_shown).
              |> put_state(:mount_id, System.unique_integer([:positive]))
              |> put_state(:page_shown?, false)
              |> put_state(:restoring?, false)
              |> put_state(:current_user_id, user_id)
              |> put_state(:current_user_username, (user && user.username) || "")
              |> put_state(:new_message, "")
              |> put_state(:rate_limited, false)
              # Private hints: a chat line of yours that was not sent (it
              # contained the word), and why a join was refused.
              |> put_state(:chat_notice, nil)
              |> put_state(:chat_notice_gen, 0)
              |> put_state(:join_notice, nil)
              |> put_state(:message_timestamps, [])
              |> put_state(:game_id, rs.game_id || "")
              |> put_state(:game_started, game_active)
              |> put_state(:round, rs.current_round)
              |> put_state(:total_rounds, rs.total_rounds)
              # Countdowns: init runs on the server, so it keeps the remaining
              # ms; :mounted anchors them on the browser's clock.
              |> put_state(:round_remaining_ms, rs.round_remaining_ms)
              |> put_state(:choice_remaining_ms, rs.choice_remaining_ms)
              |> put_state(:choice_duration, rs.choice_duration)
              |> put_state(:time_left, seconds_left(rs.round_remaining_ms))
              |> put_state(:choice_time_left, seconds_left(rs.choice_remaining_ms))
              |> put_state(:round_deadline_local, nil)
              |> put_state(:choice_deadline_local, nil)
              |> put_state(:tick_gen, System.unique_integer([:positive]))
              |> put_state(:last_tick_at, nil)
              |> put_state(:zero_since, nil)
              |> put_state(:current_drawer, drawer_of(rs, rs.players, rs.current_drawer_id))
              |> put_state(:current_word, rs.current_word)
              |> put_state(:current_word_display, rs.word_display)
              |> put_state(:word_length, rs.word_length)
              |> put_state(:revealed_word, rs.revealed_word)
              # The chosen word's difficulty, for everyone once it is chosen
              # (nil for an AI word); the choices carry their own.
              |> put_state(:word_difficulty, rs.word_difficulty)
              # The points the user's own guess scored this round (nil until
              # they guess), and the finished round during :round_end.
              |> put_state(:guess_points, rs.guess_points)
              |> put_state(:round_summary, rs.round_summary)
              |> put_state(:is_drawer, rs.is_drawer)
              |> put_state(:correct_guessers, rs.correct_guessers || [])
              |> put_state(:phase, rs.phase)
              |> put_state(:word_choices, rs.word_choices)
              |> put_state(
                :can_start_game,
                is_creator and length(rs.players) >= 2 and rs.game_id == nil
              )
              |> put_state(:chat_messages, rs.chat_messages || [])
              |> put_state(:drawing_strokes, rs.drawing_strokes || [])
              |> put_state(:draw_color, "#000000")
              |> put_state(:draw_width, 2)
              |> put_state(:draw_eraser, false)
              |> put_state(:leaving?, false)
              |> put_state(:watchers, rs.watchers || [])
              |> put_state(:answer_kind, rs.answer_kind)
              |> put_state(:themes, Map.get(rs, :themes) || [])
              |> put_state(:word_source, rs.word_source || :local)
              |> put_state(:prompt, rs.prompt || "")
              |> put_state(:creator_name, rs.creator_name || "")
              |> put_state(:round_duration, rs.round_duration || 60)
              |> put_state(:round_multiplier, rs.round_multiplier || 1)
              |> put_state(:ai_tone, rs.ai_tone || :fun)
              # The host pressed start and the start command (which makes the
              # AI call for a themed room) hasn't been answered yet.
              |> put_state(:starting_game?, false)
              |> put_state(:start_game_attempt, 0)
              # The host's settings form (RoomSettingsForm). Each opening
              # gets a new cid (`room_settings_form` counts them), so it
              # starts from the room's current settings
              # (`room_settings_initial`, taken when it opens).
              |> put_state(:show_room_settings, false)
              |> put_state(:room_settings_form, 0)
              |> put_state(:room_settings_initial, %{})
              |> put_state(:saving_room_settings?, false)
              |> put_state(:room_settings_attempt, 0)
              |> put_state(:room_settings_errors, %{})
              # "Copy invite link": :idle, :copied (for @invite_copied_ms,
              # `invite_copy_gen` names the latest copy) or :manual (the
              # browser refused, `invite_link` is shown to copy by hand). The
              # link is only ever built in the browser (room_links.mjs).
              |> put_state(:invite_copy, :idle)
              |> put_state(:invite_copy_gen, 0)
              |> put_state(:invite_link, nil)
              # A socket-only token (ScrawlyWeb.SocketToken), never the
              # session's sign-in token: state is rendered into the HTML and
              # snapshotted for Back/Forward. Refreshed by every snapshot
              # reply and after a refused connect (:game_channel_refused).
              |> put_state(:socket_token, ScrawlyWeb.SocketToken.mint(server) || "")
              |> put_state(:token_refresh_at, nil)
              |> put_state(:channel_connected, false)
              |> put_state(:channel_connecting, false)
              |> put_state(:past_games, rs.past_games || [])

            already_watching =
              user_id != nil and Enum.any?(rs.watchers || [], &(&1.id == user_id))

            # :mounted runs first on every fresh page load; `join` is the
            # join command it sends, if any. put_page/3 is ignored from init
            # (only next_action is read on mount), so the score page is
            # reached through an action.
            component =
              cond do
                rs.status == :post_game and rs.last_game_id != nil ->
                  put_action(component, :go_score, game_id: rs.last_game_id)

                already_watching ->
                  component
                  |> put_state(:watching?, true)
                  |> put_mounted(nil)

                user_id == nil ->
                  component
                  |> put_state(:watching?, true)
                  |> put_mounted(:watcher)

                Enum.any?(rs.players, &(&1.id == user_id)) ->
                  put_mounted(component, nil)

                rs.status == :lobby and length(rs.players) < rs.max_players ->
                  put_mounted(component, :player)

                true ->
                  component
                  |> put_state(:watching?, true)
                  |> put_mounted(:watcher)
              end

            {component, Commands.subscribe_to_room(server, room_id)}

          {:error, _} ->
            {room_missing(component), server}
        end

      # :room_not_found, :room_ended (dissolved rooms are never restarted)
      {:error, _} ->
        {room_missing(component), server}
    end
  end

  defp current_user_or_nil(server) do
    case ScrawlyWeb.Auth.current_user(server) do
      {:ok, user} -> user
      {:error, :unauthenticated} -> nil
    end
  end

  # put_page/3 from init never navigates: the server renders the template
  # anyway and the client only runs next_action on mount. So an unknown or
  # dissolved room renders a placeholder that reads only :room_missing?, and
  # its first action goes home.
  defp room_missing(component) do
    component
    |> put_state(:room_missing?, true)
    |> put_state(:mount_id, System.unique_integer([:positive]))
    |> put_state(:page_shown?, false)
    |> put_action(:go_home)
  end

  defp put_mounted(component, join) do
    put_action(component, name: :mounted, params: [join: join])
  end

  # A Back/Forward restore drops the pending :reset_invite_copy, so a
  # "copied" button goes back to idle (a shown link stays).
  defp restored_invite_copy(state) do
    case Map.get(state, :invite_copy) do
      :manual -> :manual
      _copied_or_idle -> :idle
    end
  end

  # First action after every fresh page load, once the DOM exists. Restores the
  # drawer's canvas from the room's strokes (independent of the game socket),
  # turns the stroke engine on or off (can_draw?/1), anchors init's
  # countdowns on the browser's clock and starts their tick chain, connects
  # the game socket for a member, and sends the join init chose (`:player` /
  # `:watcher`), whose :room_resynced reply connects it for a new member
  # (GameChannel refuses non-members).
  def action(:mounted, %{join: join}, component) do
    JS.call(:mountCanvas, [Map.get(component.state, :mount_id)])
    JS.call(:noteRoomChannel, [component.props.room_id])
    push_tool(component.state)

    if component.state.is_drawer do
      JS.call(:restoreStrokes, [component.state.drawing_strokes])
    end

    JS.call(:setDrawingEnabled, [can_draw?(component.state)])

    component =
      component
      |> put_state(:phase_entered_at, System.monotonic_time(:millisecond))
      |> anchor_countdowns(component.state)

    component = if member?(component.state), do: maybe_connect_channel(component), else: component

    case join do
      :player -> put_command(component, :join_room, room_id: component.props.room_id)
      :watcher -> put_command(component, :join_as_watcher, room_id: component.props.room_id)
      _none -> component
    end
  end

  # Dispatched by the template's inline script each time this page instance's
  # markup is put into the document: on its first render, and again when
  # Back/Forward restores the page from Hologram's snapshot. A restore runs
  # neither init nor :mounted and brings back the state (and the seq) the page
  # was left with, while the server still holds the subscriptions of the page
  # shown before (ScrawlyWeb.RoomSubscriptions). So the second time round the
  # page takes its canvas back (drawing_manager.mjs restoreCanvas: its own
  # queued stroke ops are sent again), resyncs, subscribes again and drops
  # the other pages' subscriptions. A page left through "leave" holds no
  # membership any more: it loads afresh instead, as a visit to its URL would.
  #
  # The "room not found" placeholder goes home again when it is restored
  # (init's :go_home ran only the first time).
  def action(:page_shown, _params, %{state: %{room_missing?: true}} = component) do
    component = %{component | next_page: nil}

    if Map.get(component.state, :page_shown?) == true,
      do: put_action(component, :go_home),
      else: put_state(component, :page_shown?, true)
  end

  def action(:page_shown, _params, component) do
    # Hologram 0.12.8 keeps the put_page/2 that left this page in the
    # component it saves (only next_action and next_command are cleared), so
    # after a restore the first action to return it would navigate there again
    # (Back from a game page bounced straight back to it). Drop it.
    component = %{component | next_page: nil}
    state = component.state

    cond do
      not state.page_shown? ->
        put_state(component, :page_shown?, true)

      state.leaving? ->
        JS.exec(~JS"window.location.reload()")
        component

      true ->
        JS.call(:restoreCanvas, [state.mount_id])
        push_tool(state)
        stale_rooms = JS.call(:takeStaleRoomChannels, [component.props.room_id])

        component
        |> close_room_settings()
        |> put_state(:restoring?, true)
        |> put_state(:invite_copy, restored_invite_copy(state))
        |> put_state(:last_tick_at, nil)
        |> put_state(:zero_since, nil)
        |> put_state(:resync_requested_at, nil)
        |> put_state(:stuck_seq, nil)
        |> send_resync(true, stale_rooms)
    end
  end

  def action(:do_join_as_watcher, _params, component) do
    put_command(component, :join_as_watcher, room_id: component.props.room_id)
  end

  def action(:switch_to_watcher, _params, component) do
    component
    |> put_state(:watching?, true)
    |> put_action(:do_join_as_watcher)
  end

  # ── Room broadcasts ──────────────────────────────────────────────────
  #
  # The room pushes every change on {:room, room_id}, each action stamped
  # with `seq`, one higher than the previous one (RoomServer.Broadcasts).
  # Realtime is at-most-once and replays nothing, so every {:room} action
  # follows the gap rule (accept_seq/2):
  #
  #   * ignored while leaving;
  #   * seq <= last_seq: already applied (or covered by a snapshot), dropped;
  #   * seq == last_seq + 1: applied;
  #   * seq > last_seq + 1: applied, then a resync is requested (:resync_room
  #     replies a full snapshot, :room_resynced).
  #
  # last_seq advances only from these broadcasts and from full snapshots
  # (init and :room_resynced), never from another command reply: a reply
  # carrying a seq but no chat and strokes could overtake broadcasts still in
  # flight on the stream and make the page drop them as stale.
  #
  # The drawer's word choices and word, and the word for a player who has
  # just guessed it, come separately, unsequenced, on the user's own
  # {:room_player} channel (:private_state), after the delta of the same
  # transition, and in the choose_word reply.

  def action(:room_delta, params, component) do
    case accept_seq(component, params) do
      {:apply, component, seq, gap} ->
        component
        |> put_state(:delta_seq, seq)
        |> apply_view(params, seq)
        |> after_gap(gap)

      :drop ->
        component
    end
  end

  def action(:chat_appended, %{message: message} = params, component) do
    case accept_seq(component, params) do
      {:apply, component, _seq, gap} ->
        existing = component.state.chat_messages

        component =
          if Enum.any?(existing, &(&1.id == message.id)) do
            component
          else
            component
            |> put_state(:chat_messages, Enum.take([message | existing], @max_chat))
            |> put_action(:scroll_chat)
          end

        after_gap(component, gap)

      :drop ->
        component
    end
  end

  # Viewers render the completed strokes; a drawer's tab already holds its
  # own (drawing_manager.mjs) and only takes in one drawn in another of the
  # drawer's tabs (adoptStroke). Each viewer stroke keeps the seq it arrived
  # with (stale snapshots, see :room_resynced).
  def action(:stroke_completed, params, component) do
    case accept_seq(component, params) do
      {:apply, component, seq, gap} ->
        component
        |> add_viewer_stroke(params, seq)
        |> after_gap(gap)

      :drop ->
        component
    end
  end

  # A drawer's tab only follows a clear made in another of the drawer's tabs
  # (`op_epoch` is the clearing tab's, see drawing_manager.mjs
  # applyRoomClear). Viewers keep the live preview of a stroke started after
  # the clear (clearRemoteStrokes).
  def action(:drawing_cleared, params, component) do
    case accept_seq(component, params) do
      {:apply, component, seq, gap} ->
        component =
          if component.state.is_drawer do
            JS.call(:applyRoomClear, [Map.get(params, :op_epoch)])
            component
          else
            JS.call(:clearRemoteStrokes, [])

            component
            |> put_state(:drawing_strokes, [])
            |> put_state(:strokes_seq, seq)
          end

        after_gap(component, gap)

      :drop ->
        component
    end
  end

  # Only the undone stroke's id comes (the canvas is never re-sent): a
  # viewer drops that stroke from the list it renders. Live overlays of the
  # stroke being drawn stay. strokes_seq moves on, so a stale snapshot
  # can't bring the stroke back. A drawer's tab drops it if another of the
  # drawer's tabs undid it (its own undo already did).
  def action(:drawing_undone, params, component) do
    case accept_seq(component, params) do
      {:apply, component, seq, gap} ->
        component =
          if component.state.is_drawer do
            JS.call(:forgetStroke, [Map.get(params, :stroke_id)])
            component
          else
            stroke_id = Map.get(params, :stroke_id)

            component
            |> put_state(
              :drawing_strokes,
              Enum.reject(component.state.drawing_strokes, &(&1.id == stroke_id))
            )
            |> put_state(:strokes_seq, seq)
          end

        after_gap(component, gap)

      :drop ->
        component
    end
  end

  # The user's slice (RoomServer.View.private_slice/2): the drawer's, or the
  # word for a player who has just guessed it. From the user's own
  # {:room_player} channel, after the round's delta, or the choose_word reply.
  # One for an earlier turn is ignored; one for a turn the page has not seen
  # yet (its delta was lost or is still on its way) is held until a delta
  # reaches that round.
  def action(:private_state, slice, component) do
    state = component.state
    round = Map.get(slice, :round)

    cond do
      state.leaving? or not is_integer(round) ->
        component

      Map.get(slice, :game_id) != state.game_id or round > state.round ->
        put_state(component, :pending_private, slice)

      round < state.round ->
        component

      true ->
        apply_private(component, slice)
    end
  end

  # A full snapshot (RoomServer.View.for_viewer/2 with the room's seq): the
  # join replies and :resync_room. Viewers take its chat and strokes; the
  # drawer takes everything but the canvas, so their local history and a
  # stroke in progress survive (except after a Back/Forward restore, which
  # rebuilt the canvas: then the room's strokes are merged back in).
  #
  # A snapshot older than broadcasts already applied (the reply was overtaken
  # on the stream) only fills in what it covers: chat lines are merged by id
  # (ids are seqs), room state and strokes newer than the snapshot are kept.
  def action(:room_resynced, view, component) do
    if component.state.leaving? do
      component
    else
      seq = view.seq
      state = component.state

      component =
        component
        |> put_state(:resync_requested_at, nil)
        |> put_state(:last_seq, max_seq(state.last_seq, seq))
        |> put_state(:socket_token, snapshot_socket_token(view, state))
        |> put_state(
          :chat_messages,
          merge_chat(view.chat_messages || [], state.chat_messages, seq)
        )

      component =
        if is_integer(state.delta_seq) and state.delta_seq > seq,
          do: component,
          else: component |> put_state(:delta_seq, seq) |> apply_view(view, seq)

      if component.state.leaving? do
        component
      else
        component
        |> apply_snapshot_strokes(view, seq)
        |> apply_snapshot_private(view)
        |> finish_restore(view)
        |> settle_owed_resync(seq)
      end
    end
  end

  # ── Round and word-choice countdowns ─────────────────────────────────
  #
  # The score page's deadline-anchored pattern (game_score_page.ex):
  #
  #   * The room sends what is left, as relative ms (`round_remaining_ms`,
  #     `choice_remaining_ms`), never a deadline. anchor_countdowns/2 turns
  #     them into deadlines on the browser's monotonic clock on every
  #     :room_delta and :room_resynced, and on :mounted for init's values.
  #   * :countdown_tick recomputes the seconds from those deadlines (never
  #     decrements: background tabs throttle timers) and re-puts itself, always
  #     with a delay, timed to land just after the shown second changes. The
  #     room stays authoritative: its phase change arrives as a delta, which
  #     re-anchors and starts a new chain.
  #   * Watchdog: at 0 the chain keeps ticking once a second while the page
  #     still shows the phase the countdown belongs to; after @watchdog_ms the
  #     phase change counts as lost, the page resyncs and the chain stops.
  #     While the countdown runs, a tick also notices a drawer whose private
  #     slice never came (missing_slice?/1). Either asks once per seq.
  #   * One chain at a time: ticks carry `tick_gen`, and anchoring starts a new
  #     chain (gen + 1) only when none is alive, i.e. no tick for
  #     @tick_alive_ms by `last_tick_at` (a Back/Forward snapshot restore
  #     comes back with no chain; :page_shown clears last_tick_at so the
  #     resync's snapshot restarts it).
  #   * Hologram 0.12 drops a delayed action once its page has been left, so a
  #     pending tick never lands on another page.

  def action(:countdown_tick, %{gen: gen}, component) do
    state = component.state

    cond do
      gen != state.tick_gen or state.leaving? ->
        component

      state.round_deadline_local == nil and state.choice_deadline_local == nil ->
        put_state(component, :last_tick_at, nil)

      true ->
        now = System.monotonic_time(:millisecond)
        round_ms = ms_until(state.round_deadline_local, now)
        choice_ms = ms_until(state.choice_deadline_local, now)

        component =
          component
          |> put_state(:time_left, seconds_left(round_ms))
          |> put_state(:choice_time_left, seconds_left(choice_ms))

        cond do
          round_ms > 0 or choice_ms > 0 ->
            component
            |> put_state(:last_tick_at, now)
            |> check_private_slice(now)
            |> put_tick(gen, max(round_ms, choice_ms))

          state.phase in [:choosing, :drawing] ->
            watchdog_tick(component, gen, now)

          true ->
            stop_tick_chain(component)
        end
    end
  end

  def action(:leave_room, _params, component) do
    command = if component.state.watching?, do: :leave_watcher, else: :leave_room

    component
    |> put_state(:leaving?, true)
    |> put_command(command, room_id: component.props.room_id)
  end

  def action(:room_dissolved, _params, component) do
    put_action(component, name: :go_home, delay: 1000)
  end

  def action(:go_home, _params, component) do
    leave_page(component, ScrawlyWeb.Pages.HomePage)
  end

  # Queued by init for a room in its post-game window.
  def action(:go_score, %{game_id: game_id}, component) do
    leave_page(component, ScrawlyWeb.Pages.GameScorePage, game_id: game_id)
  end

  # A command was rejected server-side (see ScrawlyWeb.Auth.deny/3): nothing
  # changed, but the page may be out of date, so it resyncs. A denied stroke
  # op leaves the drawer's op queue so the next one can go; a refused join
  # says why in the lobby; a refused leave lets the page act again (other
  # denials leave `leaving?` alone: the page may be on its way out).
  def action(:command_denied, params, component) do
    command = Map.get(params, :command)

    if command in [:complete_stroke, :undo_drawing_cmd, :clear_drawing_cmd] do
      JS.call(:rejectStrokeOp, [Map.get(params, :op_seq)])
    end

    component =
      if command in [:join_room, :join_as_watcher],
        do: put_state(component, :join_notice, join_denied_text(Map.get(params, :reason))),
        else: component

    component =
      if command in [:leave_room, :leave_watcher],
        do: put_state(component, :leaving?, false),
        else: component

    component =
      if command == :start_game, do: put_state(component, :starting_game?, false), else: component

    component =
      if command == :update_room_settings and component.state.saving_room_settings?,
        do:
          room_settings_failed(component, :form, settings_denied_text(Map.get(params, :reason))),
        else: component

    request_resync(component)
  end

  # ── Invite link ──────────────────────────────────────────────────────
  # room_links.mjs builds `<origin>/r/<code>` from window.location.origin
  # (never from the request's Host header), copies it and answers with
  # :invite_link_copied.

  def action(:copy_invite_link, _params, component) do
    code = component.state.room_code
    if is_binary(code), do: JS.call(:copyInviteLink, [code])
    component
  end

  def action(:invite_link_copied, %{copied: true}, component) do
    gen = component.state.invite_copy_gen + 1

    component
    |> put_state(:invite_copy, :copied)
    |> put_state(:invite_copy_gen, gen)
    |> put_state(:invite_link, nil)
    |> put_action(name: :reset_invite_copy, params: %{gen: gen}, delay: @invite_copied_ms)
  end

  # Nothing could copy (no Clipboard API on plain http, a refused permission,
  # no execCommand): the link is shown, selected, to copy by hand.
  def action(:invite_link_copied, %{link: link}, component) when is_binary(link) do
    JS.call(:selectInviteLink, ["invite-link"])

    component
    |> put_state(:invite_copy, :manual)
    |> put_state(:invite_link, link)
  end

  def action(:invite_link_copied, _params, component), do: component

  # Only the latest copy's: an earlier timer must not cut a later "copied" short.
  def action(:reset_invite_copy, %{gen: gen}, component) do
    state = component.state

    if state.invite_copy == :copied and gen == state.invite_copy_gen,
      do: put_state(component, :invite_copy, :idle),
      else: component
  end

  # The start button. It reads "preparing words…" until the game starts (a
  # room view with a game), the start is refused (:command_denied) or no
  # answer came for @start_game_timeout_ms.
  def action(:request_start_game, _params, component) do
    state = component.state

    if state.can_start_game and not state.starting_game? do
      attempt = state.start_game_attempt + 1

      component
      |> put_state(:starting_game?, true)
      |> put_state(:start_game_attempt, attempt)
      |> put_command(:start_game, room_id: component.props.room_id)
      |> put_action(
        name: :start_game_timed_out,
        params: %{attempt: attempt},
        delay: @start_game_timeout_ms
      )
    else
      component
    end
  end

  def action(:start_game_timed_out, %{attempt: attempt}, component) do
    state = component.state

    if state.starting_game? and attempt == state.start_game_attempt do
      component
      |> put_state(:starting_game?, false)
      |> request_resync()
    else
      component
    end
  end

  # ── Room settings (the host, in the lobby) ──────────────────────────
  # The form (RoomSettingsForm) holds the values; this page sends them and
  # shows the outcome. The form stays open, "saving…", until the server
  # answers: :room_settings_saved closes it (the change itself comes to
  # every page as a :room_delta), :room_settings_failed or a denial shows
  # why and keeps the values. No answer after @save_settings_timeout_ms
  # gives the form back. The form closes by itself when the room leaves its
  # lobby, and after a Back/Forward restore.

  def action(:edit_room_settings, _params, component) do
    state = component.state

    if can_edit_settings?(state) do
      component
      |> put_state(:show_room_settings, true)
      |> put_state(:room_settings_form, state.room_settings_form + 1)
      |> put_state(:room_settings_initial, current_settings(state))
      |> put_state(:saving_room_settings?, false)
      |> put_state(:room_settings_errors, %{})
    else
      component
    end
  end

  # Cancel, the close button, Escape. A save already sent still runs.
  def action(:hide_room_settings, _params, component), do: close_room_settings(component)

  def action(:save_room_settings, %{values: values}, component) when is_map(values) do
    state = component.state

    if state.show_room_settings and not state.saving_room_settings? and
         can_edit_settings?(state) do
      attempt = state.room_settings_attempt + 1

      component
      |> put_state(:saving_room_settings?, true)
      |> put_state(:room_settings_attempt, attempt)
      |> put_state(:room_settings_errors, %{})
      |> put_command(:update_room_settings, room_id: component.props.room_id, settings: values)
      |> put_action(
        name: :save_room_settings_timed_out,
        params: %{attempt: attempt},
        delay: @save_settings_timeout_ms
      )
    else
      component
    end
  end

  # Only while a save is waiting: a reply to a form the host has closed
  # since then changes nothing.
  def action(:room_settings_saved, _params, component) do
    if component.state.saving_room_settings?,
      do: close_room_settings(component),
      else: component
  end

  def action(:room_settings_failed, params, component) do
    if component.state.saving_room_settings?,
      do: room_settings_failed(component, Map.get(params, :field), Map.get(params, :message)),
      else: component
  end

  def action(:save_room_settings_timed_out, %{attempt: attempt}, component) do
    state = component.state

    if state.saving_room_settings? and attempt == state.room_settings_attempt,
      do: room_settings_failed(component, :form, "no answer from the server, try again"),
      else: component
  end

  def action(:choose_word, %{word: word}, component) do
    if component.state.is_drawer and component.state.phase == :choosing do
      put_command(component, :choose_word, room_id: component.props.room_id, word: word)
    else
      component
    end
  end

  # The server checks guesses, scores them and picks the display name: the
  # client only sends the typed text. The drawer short-circuit and the local
  # throttle just save round trips; the room process enforces both.
  def action(:send_message, _params, component) do
    if component.state.is_drawer do
      put_state(component, :new_message, "")
    else
      if component.state.rate_limited do
        component
      else
        message = component.state.new_message
        now = System.monotonic_time(:millisecond)
        # A stamp later than now comes from another document's clock (a
        # Back/Forward restore after a reload): it doesn't count.
        recent =
          Enum.filter(component.state.message_timestamps, fn ts ->
            is_integer(ts) and ts <= now and now - ts < 5_000
          end)

        if length(recent) >= 3 do
          component
          |> put_state(:rate_limited, true)
          |> put_state(:message_timestamps, recent)
          |> put_action(name: :clear_rate_limit, delay: 3_000)
        else
          if String.trim(message) != "" do
            component
            |> put_state(:new_message, "")
            |> put_state(:message_timestamps, [now | recent])
            |> put_command(:submit_guess, room_id: component.props.room_id, text: message)
          else
            component
          end
        end
      end
    end
  end

  # Reply to :submit_guess. Scores, guessers and chat lines arrive through
  # :room_delta / :chat_appended, and the word for a correct guess on the
  # user's own channel (:private_state). The reply itself says what only the
  # sender may know: their points, the server-side rate limit, a suppressed
  # line (it contained the word, so nobody saw it) and a near miss (one edit
  # from the word, kept off the chat too).
  def action(:guess_result, %{outcome: :correct, points: points}, component) do
    state = component.state

    component
    |> put_state(:guess_points, points)
    |> put_action(
      name: :check_guessed_word,
      params: %{game_id: state.game_id, round: state.round},
      delay: @slice_grace_ms
    )
  end

  def action(:guess_result, %{outcome: :rate_limited}, component) do
    component
    |> put_state(:rate_limited, true)
    |> put_action(name: :clear_rate_limit, delay: 3_000)
  end

  def action(:guess_result, %{outcome: :suppressed}, component),
    do: show_chat_notice(component, "not sent: your message contains the word")

  def action(:guess_result, %{outcome: :close, text: text}, component) when is_binary(text),
    do: show_chat_notice(component, PlayFeedback.close_notice(text))

  def action(:guess_result, _params, component), do: component

  # The word a correct guess earns comes on the user's own channel; still
  # missing this long after the reply (the push was lost), it comes with a
  # resync's snapshot instead.
  def action(:check_guessed_word, %{game_id: game_id, round: round}, component) do
    state = component.state

    if game_id == state.game_id and round == state.round and state.phase == :drawing and
         state.current_word in [nil, ""] and not state.leaving?,
       do: request_stuck_resync(component),
       else: component
  end

  def action(:clear_chat_notice, %{gen: gen}, component) do
    if gen == Map.get(component.state, :chat_notice_gen),
      do: put_state(component, :chat_notice, nil),
      else: component
  end

  def action(:clear_rate_limit, _params, component),
    do: put_state(component, :rate_limited, false)

  def action(:update_message, %{event: %{value: msg}}, component),
    do: put_state(component, :new_message, msg)

  def action(:clear_message, _params, component),
    do: put_state(component, :new_message, "")

  def action(:scroll_chat, _params, component) do
    JS.exec(~JS"""
      var el = document.getElementById('chat-messages');
      if (el) { el.scrollTop = el.scrollHeight; }
    """)

    component
  end

  # Dispatched on every (re)join of the game channel. Never touches the
  # canvas: the drawer's strokes live in drawing_manager.mjs (restored once per
  # mount by :mounted), the viewers' in :drawing_strokes.
  def action(:channel_connected, _params, component) do
    component
    |> put_state(:channel_connected, true)
    |> put_state(:channel_connecting, false)
  end

  # Dispatched by game_channel.mjs when the game channel refuses the join
  # (also what a socket that reconnected with an expired or revoked socket
  # token gets: it connects anonymously) or when the server closed the socket
  # (a "disconnect" broadcast after the user's tokens were revoked).
  # game_channel.mjs has closed the socket; a member asks once per
  # @token_refresh_ms for a fresh token and connects again with it. A session
  # that was signed out gets "" and stays disconnected.
  def action(:game_channel_refused, _params, component) do
    now = System.monotonic_time(:millisecond)
    at = Map.get(component.state, :token_refresh_at)

    component =
      component
      |> put_state(:channel_connected, false)
      |> put_state(:channel_connecting, false)

    cond do
      component.state.leaving? or not member?(component.state) -> component
      is_integer(at) and now >= at and now - at < @token_refresh_ms -> component
      true -> component |> put_state(:token_refresh_at, now) |> put_command(:refresh_socket_token)
    end
  end

  def action(:socket_token_refreshed, %{token: token}, component) do
    component
    |> put_state(:socket_token, token)
    |> maybe_connect_member_channel()
  end

  # The head of the drawer's op queue (drawing_manager.mjs), one op at a time.
  # An op without its tag (not from drawing_manager.mjs) is ignored.
  def action(:send_stroke_op, %{kind: kind, op_epoch: op_epoch, op_seq: op_seq} = op, component) do
    base = [room_id: component.props.room_id, op_epoch: op_epoch, op_seq: op_seq]

    case kind do
      # The turn goes along so a rejection can be matched to it.
      "commit" ->
        put_command(
          component,
          :complete_stroke,
          base ++
            [
              stroke_id: Map.get(op, :stroke_id),
              path: Map.get(op, :path),
              color: Map.get(op, :color),
              width: Map.get(op, :width),
              game_id: Map.get(component.state, :game_id),
              round: Map.get(component.state, :round)
            ]
        )

      "undo" ->
        put_command(component, :undo_drawing_cmd, base ++ [stroke_id: Map.get(op, :stroke_id)])

      "clear" ->
        put_command(component, :clear_drawing_cmd, base)

      _other ->
        component
    end
  end

  def action(:send_stroke_op, _params, component), do: component

  # Reply to every stroke op the room applied or ignored as a duplicate. It
  # carries no seq: the room's broadcast of the op does.
  def action(:stroke_op_acked, params, component) do
    JS.call(:ackStrokeOp, [Map.get(params, :op_seq)])
    component
  end

  # Reply to :complete_stroke when the server refused to store the stroke
  # (invalid, or the canvas is full): show the drawer what everyone else
  # sees. Only on the drawer's page and for the turn the stroke was drawn in
  # (the commit's game_id / round, echoed back): a late reply from an earlier
  # turn changes nothing. drawing_manager.mjs also ignores it unless its op
  # is still the head of the queue.
  def action(:stroke_rejected, %{strokes: strokes} = params, component) do
    state = component.state

    if Map.get(state, :is_drawer) == true and
         Map.get(params, :game_id) == Map.get(state, :game_id) and
         Map.get(params, :round) == Map.get(state, :round) do
      JS.call(:applyRejectedStrokes, [Map.get(params, :op_seq), strokes])
      put_state(component, :drawing_strokes, strokes)
    else
      component
    end
  end

  # The clear goes out through the op queue, after the ops queued before it.
  def action(:clear_canvas, _params, component) do
    JS.call(:clearDrawing, [])
    put_state(component, :drawing_strokes, [])
  end

  def action(:select_color, params, component) do
    color = params.color || "#000000"
    JS.call(:setToolColor, [color])

    component
    |> put_state(:draw_color, color)
    |> put_state(:draw_eraser, false)
  end

  def action(:select_width, params, component) do
    width = params.width || 2
    JS.call(:setToolWidth, [width])
    put_state(component, :draw_width, width)
  end

  def action(:toggle_eraser, _params, component), do: toggle_eraser(component)

  def action(:undo_drawing, _params, component), do: undo_last_stroke(component)

  # ── Drawer keyboard shortcuts ──────────────────────────────────────
  # The `<window>` bindings render only inside the drawer's toolbar. Key
  # filters match a superset of modifiers and fire on auto-repeat, so these
  # clauses keep only the plain press: E alone toggles once even when held,
  # Ctrl+Z / Cmd+Z undo once (no Shift: that is redo elsewhere). Ctrl+Cmd+Z
  # fires both undo bindings with the same event; the :meta one yields.

  def action(
        :shortcut_eraser,
        %{event: %{ctrl_key: false, meta_key: false, alt_key: false, repeat: false}},
        component
      ),
      do: toggle_eraser(component)

  def action(:shortcut_eraser, _params, component), do: component

  def action(:shortcut_undo, %{via: :meta, event: %{ctrl_key: true}}, component), do: component

  def action(:shortcut_undo, %{event: %{shift_key: false, repeat: false}}, component),
    do: undo_last_stroke(component)

  def action(:shortcut_undo, _params, component), do: component

  # ── Other pages' broadcasts ──────────────────────────────────────────
  # HomePage's `:lobby` actions. They reach this page when it was restored
  # by Back/Forward from the home page, until the restore's resync deletes
  # that subscription (ScrawlyWeb.RoomSubscriptions). Explicit clauses, no
  # catch-all: a new broadcast action needs one here.

  def action(:lobby_room_changed, _params, component), do: component
  def action(:lobby_room_removed, _params, component), do: component
  def action(:lobby_chat_received, _params, component), do: component
  def action(:lobby_chat_cleared, _params, component), do: component

  # Every room command needs a UUID `room_id` (plus `word` / `text` strings
  # where noted); Commands.valid_params/2 checks the shape and anything else
  # is denied (:invalid_params), as is an unknown name, so a forged request
  # never raises.
  def command(:refresh_socket_token, _params, server), do: Commands.refresh_socket_token(server)

  def command(name, params, server) when name in @room_commands do
    case Commands.valid_params(name, params) do
      {:ok, params} -> room_command(name, params, server)
      :error -> ScrawlyWeb.CommandParams.deny_invalid(server, name)
    end
  end

  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)

  defp room_command(:resync_room, params, server), do: Commands.resync_room(params, server)
  defp room_command(:join_room, params, server), do: Commands.join_room(params, server)

  defp room_command(:join_as_watcher, params, server),
    do: Commands.join_as_watcher(params, server)

  defp room_command(:leave_watcher, params, server), do: Commands.leave_watcher(params, server)
  defp room_command(:start_game, params, server), do: Commands.start_game(params, server)
  defp room_command(:leave_room, params, server), do: Commands.leave_room(params, server)
  defp room_command(:submit_guess, params, server), do: Commands.submit_guess(params, server)
  defp room_command(:choose_word, params, server), do: Commands.choose_word(params, server)

  defp room_command(:update_room_settings, params, server),
    do: Commands.update_room_settings(params, server)

  defp room_command(:complete_stroke, params, server),
    do: Commands.complete_stroke(params, server)

  defp room_command(:clear_drawing_cmd, params, server),
    do: Commands.clear_drawing_cmd(params, server)

  defp room_command(:undo_drawing_cmd, params, server),
    do: Commands.undo_drawing_cmd(params, server)

  # ── Sequencing and resync ──────────────────────────────────────────

  # The gap rule for one {:room} broadcast: :drop, or {:apply, component, seq,
  # gap} with last_seq already advanced, where gap is the highest seq that was
  # skipped (nil when none was).
  defp accept_seq(component, params) do
    state = component.state
    seq = Map.get(params, :seq)
    last = state.last_seq

    cond do
      state.leaving? or not is_integer(seq) ->
        :drop

      is_integer(last) and seq <= last ->
        :drop

      true ->
        gap = if is_integer(last) and seq > last + 1, do: seq - 1, else: nil
        {:apply, put_state(component, :last_seq, seq), seq, gap}
    end
  end

  defp after_gap(component, nil), do: component

  # A resync already in flight may have been built before the skipped
  # broadcasts: remember the highest one, :room_resynced checks it.
  defp after_gap(component, gap) do
    owed = component.state.resync_owed_seq

    component
    |> put_state(:resync_owed_seq, if(is_integer(owed), do: max(owed, gap), else: gap))
    |> request_resync()
  end

  # At most one :resync_room in flight. A reply clears resync_requested_at; a
  # request still unanswered after @resync_guard_ms may be sent again (a
  # timestamp from another document's clock, restored by Back/Forward, counts
  # as expired).
  # What the lobby says when the room refused a join (:command_denied).
  defp join_denied_text(:creator_not_present),
    do: "can't join: the host isn't in the room right now"

  defp join_denied_text(:not_in_lobby), do: "can't join: a game is in progress"

  defp join_denied_text(:rate_limited),
    do: "can't watch: you joined and left too often, try again in a minute"

  defp join_denied_text(:room_full), do: "can't watch: the room is full"
  defp join_denied_text(_reason), do: "can't join this room right now"

  defp request_resync(component) do
    state = component.state
    now = System.monotonic_time(:millisecond)
    at = state.resync_requested_at

    cond do
      state.leaving? -> component
      is_integer(at) and now >= at and now - at < @resync_guard_ms -> component
      true -> send_resync(component, false, nil)
    end
  end

  # A private hint under the chat input for 4 s (a newer one is not cut
  # short by an older one's timer).
  defp show_chat_notice(component, text) do
    gen = Map.get(component.state, :chat_notice_gen, 0) + 1

    component
    |> put_state(:chat_notice, text)
    |> put_state(:chat_notice_gen, gen)
    |> put_action(name: :clear_chat_notice, params: %{gen: gen}, delay: 4_000)
  end

  # The countdown watchdog and the missing-slice check ask once per seq: a
  # room that is really stuck (or a drawer with really no choices) costs one
  # resync, not one every few seconds.
  defp request_stuck_resync(component) do
    if component.state.stuck_seq == component.state.last_seq do
      component
    else
      component
      |> put_state(:stuck_seq, component.state.last_seq)
      |> request_resync()
    end
  end

  # `stale_rooms` (a restore only): the other rooms whose channels the tab
  # may still be subscribed to (room_channels.mjs).
  defp send_resync(component, resubscribe, stale_rooms) do
    params = [room_id: component.props.room_id, resubscribe: resubscribe]
    params = if is_list(stale_rooms), do: params ++ [stale_rooms: stale_rooms], else: params

    component
    |> put_state(:resync_requested_at, System.monotonic_time(:millisecond))
    |> put_command(:resync_room, params)
  end

  # The snapshot answered the request; a gap seen meanwhile that it does not
  # cover gets a new one.
  defp settle_owed_resync(component, seq) do
    owed = component.state.resync_owed_seq

    if is_integer(owed) and owed > seq do
      request_resync(component)
    else
      put_state(component, :resync_owed_seq, nil)
    end
  end

  # Snapshot replies carry a fresh socket token ("" once signed out).
  defp snapshot_socket_token(view, state) do
    case Map.fetch(view, :socket_token) do
      {:ok, token} when is_binary(token) -> token
      {:ok, _none} -> ""
      :error -> state.socket_token
    end
  end

  defp max_seq(last, seq) when is_integer(last) and last > seq, do: last
  defp max_seq(_last, seq), do: seq

  # Chat ids are seqs: lines newer than the snapshot stay, in front of it
  # (both lists are newest first, and every newer id is above the snapshot's).
  defp merge_chat(snapshot_chat, local_chat, seq) do
    newer = Enum.filter(local_chat, fn msg -> is_integer(msg.id) and msg.id > seq end)
    Enum.take(newer ++ snapshot_chat, @max_chat)
  end

  defp add_viewer_stroke(component, params, seq) do
    if component.state.is_drawer do
      JS.call(:adoptStroke, [
        %{
          id: Map.get(params, :stroke_id),
          path: Map.get(params, :path),
          color: Map.get(params, :color),
          width: Map.get(params, :width)
        }
      ])

      component
    else
      strokes = component.state.drawing_strokes
      JS.call(:removeRemoteOverlay, [params.stroke_id])

      if Enum.any?(strokes, &(&1.id == params.stroke_id)) do
        component
      else
        stroke = %{
          id: params.stroke_id,
          path: params.path || "",
          color: params.color || "#000000",
          width: params.width || 2,
          seq: seq
        }

        put_state(component, :drawing_strokes, strokes ++ [stroke])
      end
    end
  end

  # Viewers take the snapshot's strokes, plus strokes that arrived after it
  # (unless the list was replaced after it: then theirs is newer). The live
  # overlays of strokes it holds go; those of strokes still being drawn stay.
  defp apply_snapshot_strokes(component, view, seq) do
    state = component.state

    cond do
      state.is_drawer ->
        component

      is_integer(state.strokes_seq) and state.strokes_seq > seq ->
        component

      true ->
        room = view.drawing_strokes || []

        newer =
          Enum.filter(state.drawing_strokes, fn s ->
            Map.get(s, :seq, 0) > seq and not Enum.any?(room, &(&1.id == s.id))
          end)

        strokes = room ++ newer
        JS.call(:settleRemoteStrokes, [Enum.map(strokes, & &1.id)])

        component
        |> put_state(:drawing_strokes, strokes)
        |> put_state(:strokes_seq, seq)
    end
  end

  # The word fields of the drawer, or of a player who has guessed the word,
  # in a snapshot, applied like a pushed slice.
  defp apply_snapshot_private(component, view) do
    if Map.get(view, :is_drawer) == true or Map.get(view, :current_word) != nil do
      slice = %{
        game_id: view.game_id || "",
        round: view.current_round || 0,
        phase: view.phase,
        current_word: view.current_word,
        word_choices: view.word_choices || [],
        guess_points: Map.get(view, :guess_points)
      }

      if slice.game_id == component.state.game_id and slice.round == component.state.round,
        do: apply_private(component, slice),
        else: component
    else
      component
    end
  end

  # After a Back/Forward restore: the drawer's canvas becomes the room's
  # strokes plus their own ops still queued (rebaseCanvas), drawing follows
  # the room's phase again, and the game socket (closed or stale since the
  # page was left) is joined again for a member.
  defp finish_restore(component, view) do
    if component.state.restoring? do
      if component.state.is_drawer do
        JS.call(:rebaseCanvas, [view.drawing_strokes || []])
      end

      JS.call(:setDrawingEnabled, [can_draw?(component.state)])

      component = put_state(component, :restoring?, false)

      if member?(component.state) and component.state.socket_token != "" do
        JS.call(:ensureGameChannel, [component.state.socket_token, component.state.room_code])
      else
        JS.call(:disconnectGameChannel, [])
      end

      component
    else
      maybe_connect_member_channel(component)
    end
  end

  defp maybe_connect_member_channel(component) do
    if member?(component.state), do: maybe_connect_channel(component), else: component
  end

  # Applies a slice for the page's current turn. Phases only move forward
  # within a turn, so a slice behind the page's phase (a :choosing one landing
  # after the commit) changes nothing.
  defp apply_private(component, slice) do
    if phase_rank(slice.phase) >= phase_rank(component.state.phase) do
      component
      |> put_state(:current_word, slice.current_word)
      |> put_state(:word_choices, slice.word_choices || [])
      |> put_state(
        :guess_points,
        Map.get(slice, :guess_points) || Map.get(component.state, :guess_points)
      )
    else
      component
    end
  end

  defp apply_pending_private(component) do
    state = component.state

    case state.pending_private do
      %{game_id: game_id, round: round} = slice ->
        cond do
          game_id == state.game_id and round == state.round ->
            component
            |> put_state(:pending_private, nil)
            |> apply_private(slice)

          game_id == state.game_id and round < state.round ->
            put_state(component, :pending_private, nil)

          true ->
            component
        end

      _none ->
        component
    end
  end

  defp phase_rank(:choosing), do: 1
  defp phase_rank(:drawing), do: 2
  defp phase_rank(:round_end), do: 3
  defp phase_rank(_phase), do: 0

  # The drawer is choosing with nothing to choose from, or drawing without a
  # word: their slice was lost.
  defp missing_slice?(state) do
    state.is_drawer and
      ((state.phase == :choosing and state.word_choices == [] and state.current_word == nil) or
         (state.phase == :drawing and state.current_word in [nil, ""]))
  end

  defp check_private_slice(component, now) do
    entered = component.state.phase_entered_at

    if missing_slice?(component.state) and is_integer(entered) and
         now - entered >= @slice_grace_ms,
       do: request_stuck_resync(component),
       else: component
  end

  defp member?(state) do
    uid = state.current_user_id

    uid != nil and
      (Enum.any?(state.players, &(&1.id == uid)) or Enum.any?(state.watchers, &(&1.id == uid)))
  end

  # ── Room settings helpers ───────────────────────────────────────────

  # The host, in the lobby, before a start is on its way.
  defp can_edit_settings?(state) do
    state.is_creator and not state.watching? and state.room_status == :lobby and
      not state.game_started and not state.starting_game?
  end

  # The room's settings as the page holds them, for the form to start from.
  defp current_settings(state) do
    %{
      name: state.room_name,
      max_players: state.max_players,
      answer_kind: state.answer_kind,
      themes: state.themes,
      word_source: state.word_source,
      prompt: state.prompt,
      round_duration: state.round_duration,
      round_multiplier: state.round_multiplier,
      ai_tone: state.ai_tone
    }
  end

  defp close_room_settings(component) do
    component
    |> put_state(:show_room_settings, false)
    |> put_state(:saving_room_settings?, false)
    |> put_state(:room_settings_errors, %{})
  end

  defp room_settings_failed(component, field, message) do
    component
    |> put_state(:saving_room_settings?, false)
    |> put_state(:room_settings_errors, %{(field || :form) => message})
  end

  defp settings_denied_text(:wrong_state), do: "settings can only change in the lobby"
  defp settings_denied_text(:not_creator), do: "only the host can change the settings"
  defp settings_denied_text(_reason), do: "couldn't save the settings, try again"

  # ── The one reducer ─────────────────────────────────────────────────
  #
  # Applies the room's public state from a :room_delta (View.delta/1) or a
  # snapshot (View.for_viewer/2) whose `seq` is given: membership, game,
  # round, phase, drawer, the word fields everyone sees, the countdowns, the
  # canvas reset on a new game or turn, and the redirects.
  defp apply_view(component, view, seq) do
    cond do
      view.status == :post_game and Map.get(view, :last_game_id) != nil ->
        leave_page(component, ScrawlyWeb.Pages.GameScorePage, game_id: view.last_game_id)

      view.status == :ended ->
        component
        |> put_state(:room_status, :ended)
        |> put_action(name: :go_home, delay: 2000)

      true ->
        update_from_view(component, view, seq)
    end
  end

  defp update_from_view(component, view, seq) do
    state = component.state
    players = view.players || []
    game_id = view.game_id
    active = game_id != nil
    round = view.current_round || 0
    phase = view.phase || :idle
    drawer_id = view.current_drawer_id
    uid = state.current_user_id

    new_game = active and (not state.game_started or game_id != state.game_id)
    new_turn = new_game or (active and round != state.round)
    game_over = state.game_started and not active

    joined? = is_binary(uid) and Enum.any?(players, &(&1.id == uid))

    # Taken out of the lobby without leaving from this tab: the room's
    # presence sweep (no open tab for a while, e.g. a frozen background
    # tab) or another tab's leave. The lobby offers to join again.
    dropped? =
      not joined? and not state.leaving? and view.status == :lobby and is_binary(uid) and
        Enum.any?(state.players, &(&1.id == uid))

    join_notice =
      cond do
        joined? -> nil
        dropped? -> "you're no longer in this room"
        true -> Map.get(state, :join_notice)
      end

    component =
      component
      |> put_state(:players, players)
      |> put_state(:join_notice, join_notice)
      |> put_state(:max_players, Map.get(view, :max_players) || state.max_players)
      |> put_state(:watchers, view.watchers || [])
      |> put_state(:room_status, view.status)
      |> put_state(:correct_guessers, view.correct_guessers || [])
      |> put_state(:past_games, Map.get(view, :past_games) || state.past_games)
      |> put_state(
        :can_start_game,
        state.is_creator and length(players) >= 2 and game_id == nil
      )
      |> put_state(:starting_game?, Map.get(state, :starting_game?, false) and game_id == nil)
      |> put_state(:game_started, active)
      |> put_state(:game_id, game_id || "")
      |> put_state(:round, round)
      |> put_state(:total_rounds, view.total_rounds || state.total_rounds)
      |> put_state(:current_drawer, drawer_of(view, players, drawer_id))
      |> put_state(:is_drawer, is_binary(uid) and uid == drawer_id)
      |> put_state(:phase, phase)
      |> put_state(:current_word_display, Map.get(view, :word_display, ""))
      |> put_state(:word_length, Map.get(view, :word_length, 0))
      |> put_state(:revealed_word, Map.get(view, :revealed_word))
      |> put_state(:word_difficulty, Map.get(view, :word_difficulty))
      |> put_state(:round_summary, Map.get(view, :round_summary))
      |> put_settings(view)

    # The settings form is the lobby's: it goes when the room leaves it.
    component =
      if active or view.status != :lobby,
        do: close_room_settings(component),
        else: component

    component =
      if new_turn or game_over,
        do: reset_turn(component, seq),
        else: end_drawing_phase(component, state.phase, phase)

    component = sync_drawing_enabled(component, state)

    component =
      if new_turn or game_over or phase != state.phase,
        do: put_state(component, :phase_entered_at, System.monotonic_time(:millisecond)),
        else: component

    component
    |> apply_pending_private()
    |> anchor_countdowns(view)
  end

  # The room's settings from a delta or a snapshot (RoomServer.View.settings/1;
  # the host may change them in the lobby). A key the view lacks keeps its
  # value; round_duration follows the countdowns (put_countdown_anchors/2).
  defp put_settings(component, view) do
    state = component.state

    component
    |> put_state(:room_name, Map.get(view, :name) || Map.get(state, :room_name))
    |> put_state(:answer_kind, Map.get(view, :answer_kind) || Map.get(state, :answer_kind))
    |> put_state(:themes, Map.get(view, :themes) || Map.get(state, :themes) || [])
    |> put_state(:word_source, Map.get(view, :word_source) || Map.get(state, :word_source))
    |> put_state(:prompt, Map.get(view, :prompt, Map.get(state, :prompt)) || "")
    |> put_state(
      :round_multiplier,
      Map.get(view, :round_multiplier) || Map.get(state, :round_multiplier)
    )
    |> put_state(:ai_tone, Map.get(view, :ai_tone) || Map.get(state, :ai_tone))
  end

  # The drawer as the canvas header shows them: name and avatar.
  defp drawer_of(_view, _players, nil), do: nil

  defp drawer_of(view, players, drawer_id) do
    player = Enum.find(players || [], &(&1.id == drawer_id))

    %{
      id: drawer_id,
      username: Map.get(view, :drawer_name) || (player && player.username) || "Unknown",
      avatar_id: (player && Map.get(player, :avatar_id)) || "a-mushroom",
      avatar_color: (player && Map.get(player, :avatar_color)) || "3"
    }
  end

  # A new game, a new turn or the end of the game: an empty canvas for
  # everyone (the drawer's local history and op queue included), no word
  # until the new drawer's slice arrives and no guess yet.
  defp reset_turn(component, seq) do
    JS.call(:setDrawingPath, [""])

    component
    |> put_state(:drawing_strokes, [])
    |> put_state(:strokes_seq, seq)
    |> put_state(:current_word, nil)
    |> put_state(:word_choices, [])
    |> put_state(:guess_points, nil)
  end

  # Anchors the countdowns from a view, delta or init state (see the
  # countdown section above) and starts a tick chain unless one is alive.
  defp anchor_countdowns(component, params) do
    component
    |> put_countdown_anchors(params)
    |> ensure_tick_chain()
  end

  defp put_countdown_anchors(component, params) do
    now = System.monotonic_time(:millisecond)
    round_ms = Map.get(params, :round_remaining_ms) || 0
    choice_ms = Map.get(params, :choice_remaining_ms) || 0

    component
    |> put_state(:round_deadline_local, local_deadline(now, round_ms))
    |> put_state(:choice_deadline_local, local_deadline(now, choice_ms))
    |> put_state(:zero_since, nil)
    |> put_state(:time_left, seconds_left(round_ms))
    |> put_state(:choice_time_left, seconds_left(choice_ms))
    |> put_state(
      :choice_duration,
      Map.get(params, :choice_duration) || Map.get(component.state, :choice_duration)
    )
    |> put_state(
      :round_duration,
      Map.get(params, :round_duration) || Map.get(component.state, :round_duration)
    )
  end

  defp ensure_tick_chain(component) do
    state = component.state
    now = System.monotonic_time(:millisecond)
    round_ms = ms_until(state.round_deadline_local, now)
    choice_ms = ms_until(state.choice_deadline_local, now)

    if (round_ms > 0 or choice_ms > 0) and not chain_alive?(state.last_tick_at, now) do
      gen = state.tick_gen + 1

      component
      |> put_state(:tick_gen, gen)
      |> put_state(:last_tick_at, now)
      |> put_tick(gen, max(round_ms, choice_ms))
    else
      component
    end
  end

  # The countdown reached 0 but the phase it counts down is still shown.
  defp watchdog_tick(component, gen, now) do
    since = component.state.zero_since || now

    if now - since >= @watchdog_ms do
      component
      |> stop_tick_chain()
      |> request_stuck_resync()
    else
      component
      |> put_state(:zero_since, since)
      |> put_state(:last_tick_at, now)
      |> put_tick(gen, 0)
    end
  end

  defp stop_tick_chain(component) do
    component
    |> put_state(:round_deadline_local, nil)
    |> put_state(:choice_deadline_local, nil)
    |> put_state(:last_tick_at, nil)
    |> put_state(:zero_since, nil)
  end

  # A tick ran (or a chain started) less than @tick_alive_ms ago. `last` is
  # from this document's clock unless a snapshot restore brought an older one
  # back, hence the >= 0.
  defp chain_alive?(last, now) when is_integer(last),
    do: now - last >= 0 and now - last < @tick_alive_ms

  defp chain_alive?(_last, _now), do: false

  # Lands just after the shown whole second changes (ms is what is left now),
  # so ticks never drift past a second and skip a number. Always a delay: an
  # action that re-puts itself without one never yields to the browser.
  defp put_tick(component, gen, ms) do
    delay =
      if ms > 0,
        do: ms - (seconds_left(ms) - 1) * 1000 + @tick_slack_ms,
        else: @tick_ms

    put_action(component, name: :countdown_tick, params: %{gen: gen}, delay: delay)
  end

  defp local_deadline(now, ms) when is_integer(ms) and ms > 0, do: now + ms
  defp local_deadline(_now, _ms), do: nil

  defp ms_until(deadline, now) when is_integer(deadline), do: max(0, deadline - now)
  defp ms_until(_deadline, _now), do: 0

  # Whole seconds shown for `ms` left: rounded up, so 0 only once time is up.
  defp seconds_left(ms) when is_integer(ms) and ms > 0, do: div(ms + 999, 1000)
  defp seconds_left(_ms), do: 0

  # Leaving :drawing (time up, everyone guessed) ends the stroke in progress
  # and the viewers' live overlays: the room will not store either.
  defp end_drawing_phase(component, :drawing, new_phase) when new_phase != :drawing do
    JS.call(:endDrawingPhase, [])
    component
  end

  defp end_drawing_phase(component, _old_phase, _new_phase), do: component

  @doc """
  Whether the page's user may draw: the drawer, while the room is in
  `:drawing`. The room decides when drawing ends, so the gate is the phase,
  never the local countdown (which only clamps at 0 and waits for the phase
  change). drawing_manager.mjs's stroke engine follows it
  (`setDrawingEnabled`); turning it off drops a stroke in progress.
  """
  def can_draw?(state),
    do: Map.get(state, :is_drawer) == true and Map.get(state, :phase) == :drawing

  # After the reducer changed is_drawer or the phase.
  defp sync_drawing_enabled(component, old_state) do
    allowed = can_draw?(component.state)

    if allowed != can_draw?(old_state) do
      JS.call(:setDrawingEnabled, [allowed])
    end

    component
  end

  # Shared by the toolbar buttons and the keyboard shortcuts.
  defp toggle_eraser(component) do
    component =
      put_state(component, :draw_eraser, not Map.get(component.state, :draw_eraser, false))

    push_tool(component.state)
    component
  end

  # The tool the toolbar shows, into drawing_manager.mjs (whose tool is
  # shared by every page instance of the tab): on :mounted, after a
  # Back/Forward restore, and when the eraser toggles.
  defp push_tool(state) do
    if Map.get(state, :draw_eraser, false) do
      JS.call(:setToolColor, ["#FFFFFF"])
      JS.call(:setToolWidth, [20])
    else
      JS.call(:setToolColor, [Map.get(state, :draw_color, "#000000")])
      JS.call(:setToolWidth, [Map.get(state, :draw_width, 2)])
    end
  end

  defp undo_last_stroke(component) do
    JS.call(:undoStroke, [])
    component
  end

  # Every navigation away from GamePage that the page itself starts: the game
  # socket would otherwise stay joined (header links are handled by the
  # marker check in game_channel.mjs). Sets leaving?, so nothing that is
  # still queued for this page acts on it.
  defp leave_page(component, page, params \\ []) do
    JS.call(:disconnectGameChannel, [])
    component = put_state(component, :leaving?, true)

    if params == [],
      do: put_page(component, page),
      else: put_page(component, page, params)
  end

  defp maybe_connect_channel(component) do
    connected = Map.get(component.state, :channel_connected, false)
    connecting = Map.get(component.state, :channel_connecting, false)
    token = Map.get(component.state, :socket_token, "")
    room_code = component.state.room_code

    if not connected and not connecting and token != "" and room_code != nil do
      JS.call(:connectGameChannel, [token, room_code])
      put_state(component, :channel_connecting, true)
    else
      component
    end
  end

  # An unknown or dissolved room only sets :room_missing?, so the placeholder
  # must read no other state ({%if} compiles to `if`: the else branch is never
  # evaluated). The marker stays out of it: the placeholder is no game page
  # for drawing_manager.mjs / game_channel.mjs.
  #
  # The inline script dispatches :page_shown whenever this page instance's
  # markup is inserted (Hologram runs the inline scripts a patch inserts, and
  # keys a script by its text, so @mount_id makes it run once per instance).
  #
  # The answer and its blanks render one `.word-chunk` per word
  # (ScrawlyWeb.PlayFeedback), so a line only ever breaks between words.
  def template do
    ~HOLO"""
    {%if @room_missing?}
    <div class="page page-mid">
      <script>Hologram.dispatchAction("page_shown", "page", \{mount_id: "{@mount_id}"\});</script>
      <div class="mono" style="font-size: 12px; color: var(--muted);">room not found · returning to the lobby…</div>
    </div>
    {%else}
    <span id="game-page-marker" data-mount={@mount_id} hidden={true}></span>
    <script>Hologram.dispatchAction("page_shown", "page", \{mount_id: "{@mount_id}"\});</script>
    {%if !@game_started}
    <div class="page page-mid">
      <div class="row" style="margin-bottom: 24px;">
        <button class="app-btn app-btn-ghost app-btn-sm" $click={:leave_room}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="14" height="14"><path d="M19 12H5M11 6l-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          back to rooms
        </button>
        <span class="mono" style="font-size: 11px; color: var(--muted); margin-left: 8px;">
          room · {@room_name}
        </span>
      </div>

      <div class="lobby-grid">
        <div class="surface lobby-panel">
          <div class="between" style="align-items: flex-start; margin-bottom: 16px;">
            <div>
              <h1 class="lobby-title">{@room_name}</h1>
              <div class="lobby-sub">
                {%if @watching?}you are watching{%else}{%if @is_creator}waiting for players · you can start{%else}waiting for the host to start the game{/if}{/if}
              </div>
            </div>
            <span class="chip chip-strong">lobby</span>
          </div>

          <div class="lobby-invite">
            <div class="lobby-code">
              <span class="label">code</span>
              <span class="code">{@room_code}</span>
              <button type="button" class="app-btn app-btn-sm" $click="copy_invite_link">
                {%if @invite_copy == :copied}copied{%else}copy invite link{/if}
              </button>
            </div>
            {%if @invite_copy == :manual}
              <div class="invite-manual">
                <label class="field-label" for="invite-link">copy this link</label>
                <input class="app-input mono" id="invite-link" type="text" readonly={true} value={@invite_link} />
                <div class="field-hint">your browser didn't let us copy it. select the link and copy it.</div>
              </div>
            {/if}
          </div>

          <div class="section-label" style="margin-bottom: 10px;">players · {length(@players)}/{@max_players}</div>
          <div class="player-list">
            {%for player <- @players}
              <div class="player-row">
                <span class="av" style={"background: " <> Scrawly.Games.PlayerColor.for(player.id) <> "; color: #0a0a0a;"}>
                  {String.upcase(String.slice(player.username || "?", 0..0))}
                </span>
                <span class="name">{player.username}</span>
                {%if player.id == @creator_id}<span class="chip chip-accent">host</span>{/if}
                {%if player.id == @current_user_id}<span class="chip chip-strong">you</span>{/if}
                <span class="tag">ready</span>
              </div>
            {/for}
            {%if @max_players - length(@players) > 0}
              {%for _i <- 1..(@max_players - length(@players))}
                <div class="player-row" style="opacity: 0.5;">
                  <span class="av" style="background: transparent; border: 1px dashed var(--hairline-2); color: var(--muted);">·</span>
                  <span class="name" style="color: var(--muted);">open slot</span>
                  <span class="tag">empty</span>
                </div>
              {/for}
            {/if}
          </div>

          <div class="row" style="margin-top: 24px; gap: 8px;">
            {%if @is_creator}
              <button class="app-btn app-btn-primary app-btn-lg" style="flex: 1;"
                      disabled={!@can_start_game or @starting_game?}
                      $click="request_start_game">
                {%if @starting_game?}preparing words…{%else}{%if @can_start_game}start game{%else}need 2+ players{/if}{/if}
              </button>
            {/if}
            {%if @join_notice != nil and @current_user_id != nil and !@watching? and length(@players) < @max_players and !Enum.any?(@players, fn p -> p.id == @current_user_id end)}
              <button class="app-btn app-btn-primary app-btn-lg" style="flex: 1;"
                      $click={command: :join_room, params: %{room_id: @room_id}}>
                join
              </button>
            {/if}
            <button class="app-btn app-btn-lg" $click={:leave_room}>leave</button>
          </div>
          {%if @join_notice}
            <div class="mono" style="font-size: 12px; color: var(--danger); margin-top: 10px; text-align: center;">{@join_notice}</div>
          {/if}
          <div class="mono" style="font-size: 11px; color: var(--muted); margin-top: 10px; text-align: center;">
            send the link or the code to your friends
          </div>
        </div>

        <div>
          <div class="surface" style="overflow: hidden;">
            <div class="panel-head">
              <span>settings</span>
              {%if @is_creator and !@watching?}
                <button type="button" class="app-btn app-btn-sm panel-head-btn"
                        disabled={@starting_game?} $click="edit_room_settings">edit</button>
              {/if}
            </div>
            <div class="spec-grid">
              <div class="spec"><div class="k">answers</div><div class="v">{RoomSettings.answers_label(@answer_kind)}</div></div>
              <div class="spec"><div class="k">draw time</div><div class="v">{RoomSettings.draw_time_label(@round_duration)}</div></div>
              <div class="spec"><div class="k">turns each</div><div class="v">{@round_multiplier}</div></div>
              <div class="spec"><div class="k">topic</div><div class="v">{RoomSettings.topic_label(@word_source, @themes)}</div></div>
              {%if @word_source != :ai and RoomSettings.themes_label(@themes)}
                <div class="spec" style="grid-column: 1 / -1; border-right: 0;">
                  <div class="k">themes</div>
                  <div class="v" style="font-size: 14px; color: var(--ink-2);" title={RoomSettings.themes_list(@themes)}>{RoomSettings.themes_label(@themes)}</div>
                </div>
              {/if}
              {%if RoomSettings.theme(%{word_source: @word_source, prompt: @prompt})}
                <div class="spec" style="grid-column: 1 / -1; border-right: 0;">
                  <div class="k">theme</div>
                  <div class="v" style="font-size: 14px; color: var(--ink-2); overflow-wrap: anywhere;">{@prompt}</div>
                  <div class="mono" style="font-size: 11px; color: var(--muted); margin-top: 4px;">style: {@ai_tone}</div>
                </div>
              {/if}
            </div>
          </div>

          {%if length(@watchers) > 0}
            <div class="surface" style="margin-top: 16px; padding: 16px;">
              <div class="row" style="margin-bottom: 10px;">
                <span class="section-label">watching · {length(@watchers)}</span>
                <span class="mono" style="font-size: 11px; color: var(--muted); margin-left: auto;">spectators don't score</span>
              </div>
              <div class="row" style="flex-wrap: wrap; gap: 6px;">
                {%for w <- @watchers}
                  <span class="chip chip-name">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="12" height="12"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z" stroke-linejoin="round"/><circle cx="12" cy="12" r="3"/></svg>
                    {w.username}
                  </span>
                {/for}
              </div>
            </div>
          {/if}

          {%if length(@past_games) > 0}
            <div style="margin-top: 16px; padding: 16px; border: 1px dashed var(--hairline-2); border-radius: 8px;">
              <div class="section-label" style="margin-bottom: 8px;">past games in this room</div>
              <div class="mono" style="font-size: 12px; color: var(--muted); line-height: 1.7;">
                {%for game <- @past_games}
                  <div>
                    <span style="color: var(--ink);">{game.total_rounds} rounds</span>
                    {%if game.winner} · winner: <span style="color: var(--ink);">{game.winner.username}</span> ({game.winner.score} pts){/if}
                    · <a href={"/game-results/" <> game.game_id} style="color: var(--ink); text-decoration: underline;">view results</a>
                  </div>
                {/for}
              </div>
            </div>
          {/if}
        </div>
      </div>

      {%if @show_room_settings}
        <div class="scrim">
          <RoomSettingsForm cid={"room-settings-" <> Integer.to_string(@room_settings_form)}
                            initial={@room_settings_initial}
                            on_submit={:save_room_settings} on_cancel={:hide_room_settings}
                            busy={@saving_room_settings?} errors={@room_settings_errors}
                            min_players={max(length(@players), 2)}
                            title="room settings"
                            subtitle="the next game plays with these. everyone here sees the change."
                            submit_label="save" busy_label="saving…"
                            name_placeholder={RoomSettings.default_name(@current_user_username)} />
        </div>
      {/if}
    </div>
    {/if}

    {%if @game_started}
    <div>
      <div class="game-bar">
        <div class="game-bar-inner">
          <div class="left">
            <button class="app-btn app-btn-ghost app-btn-sm" $click={:leave_room}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="14" height="14"><path d="M19 12H5M11 6l-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
              leave
            </button>
            <span class="section-label">{@room_name} · {@room_code}</span>
            <span class="chip chip-live">live</span>
          </div>
          <div class="word-display">
            {%if @phase == :choosing}
              <div class="word-letters" style="opacity: 0.5;">— — —</div>
              <div class="word-meta">
                {%if @is_drawer}choose a word to draw{%else}{(@current_drawer && @current_drawer.username) || "drawer"} is choosing …{/if}
              </div>
            {%else}
              {%if @revealed_word}
                <div class="word-letters">
                  {%for w <- PlayFeedback.word_blocks(String.upcase(@revealed_word))}<span class="word-chunk">{w}</span>{/for}
                </div>
              {%else}
                {%if @current_word}
                  <div class={"word-letters" <> if(@is_drawer, do: "", else: " got-it")}>
                    {%for w <- PlayFeedback.word_blocks(String.upcase(@current_word))}<span class="word-chunk">{w}</span>{/for}
                  </div>
                {%else}
                  <div class="word-letters masked">
                    {%for w <- PlayFeedback.mask_blocks(@current_word_display)}<span class="word-chunk">{w}</span>{/for}
                  </div>
                {/if}
              {/if}
              <div class="word-meta">
                {%if @is_drawer}
                  your word · {PlayFeedback.word_label(@current_word_display, @word_length)}
                {%else}
                  {%if @phase == :drawing and PlayFeedback.guessed?(@correct_guessers, @current_user_id, @guess_points)}
                    <span class="got-it">{PlayFeedback.got_it(@guess_points)}</span>
                  {%else}
                    round {@round} of {@total_rounds} · {PlayFeedback.word_label(@current_word_display, @word_length)}
                  {/if}
                {/if}
                {%if @word_difficulty}<span class={PlayFeedback.difficulty_class(@word_difficulty)}>{PlayFeedback.difficulty_label(@word_difficulty)}</span>{/if}
              </div>
            {/if}
          </div>
          <div class="right">
            <div>
              {%if @total_rounds && @total_rounds > 0}
                {%for i <- 1..@total_rounds}
                  {%if i < @round}<span class="round-pip on"></span>{%else}{%if i == @round}<span class="round-pip now"></span>{%else}<span class="round-pip"></span>{/if}{/if}
                {/for}
              {/if}
            </div>
            <div class="col" style="align-items: center; gap: 4px;">
              {%if @phase == :choosing}
                <div class="timer timer-big mono">{@choice_time_left}s</div>
                <div class="bar accent" style="width: 80px;"><div style={"width: " <> Integer.to_string(min(100, round((@choice_time_left / max(@choice_duration, 1)) * 100))) <> "%;"}></div></div>
              {%else}
                <div class="timer timer-big mono">{@time_left}s</div>
                <div class="bar accent" style="width: 80px;"><div style={"width: " <> Integer.to_string(min(100, round((@time_left / max(@round_duration, 1)) * 100))) <> "%;"}></div></div>
              {/if}
            </div>
          </div>
        </div>
      </div>

      {%if @phase == :choosing}
        <div class="choice-overlay">
          <div class="choice-modal">
            {%if @is_drawer}
              <div class="choice-title">choose a word to draw</div>
              <div class="choice-sub mono">{@choice_time_left}s to pick · auto-picks at 0</div>
              <div class="choice-options">
                {%for w <- @word_choices}
                  <button class="choice-btn" $click={:choose_word, word: w.text}>
                    <span class="choice-word">{w.text}</span>
                    {%if w.difficulty}<span class={PlayFeedback.difficulty_class(w.difficulty)}>{PlayFeedback.difficulty_label(w.difficulty)}</span>{/if}
                  </button>
                {/for}
              </div>
            {%else}
              <div class="choice-title">{(@current_drawer && @current_drawer.username) || "drawer"} is choosing a word</div>
              <div class="choice-sub mono">{@choice_time_left}s remaining</div>
              <div class="choice-dots">
                <span></span><span></span><span></span>
              </div>
            {/if}
          </div>
        </div>
      {/if}

      {%if @phase == :round_end and @round_summary}
        <div class="choice-overlay round-summary-overlay">
          <div class="choice-modal round-summary" role="status">
            <div class="round-summary-head mono">
              round {@round_summary.round} · the answer was
              {%if @round_summary.difficulty}<span class={PlayFeedback.difficulty_class(@round_summary.difficulty)}>{PlayFeedback.difficulty_label(@round_summary.difficulty)}</span>{/if}
            </div>
            <div class="word-letters round-summary-answer">
              {%for w <- PlayFeedback.word_blocks(String.upcase(@round_summary.word || ""))}<span class="word-chunk">{w}</span>{/for}
            </div>
            <div class="round-summary-rows">
              {%for row <- @round_summary.players}
                <div class={"round-summary-row" <> if(row.id == @current_user_id, do: " me", else: "")}>
                  <span class="nm">
                    {%if row.guessed}<span class="mark guessed" role="img" aria-label="guessed it">✓</span>{%else}<span class="mark"></span>{/if}
                    {row.username}
                  </span>
                  <span class={"pts mono" <> if(row.points > 0, do: "", else: " none")}>{PlayFeedback.points_label(row.points)}</span>
                </div>
              {/for}
              <div class={"round-summary-row drawer" <> if(@round_summary.drawer_id == @current_user_id, do: " me", else: "")}>
                <span class="nm">
                  <span class="mark" role="img" aria-label="drew">✎</span>
                  {@round_summary.drawer_name} <span class="role">drew</span>
                </span>
                <span class={"pts mono" <> if(@round_summary.drawer_points > 0, do: "", else: " none")}>{PlayFeedback.points_label(@round_summary.drawer_points)}</span>
              </div>
            </div>
            <div class="round-summary-next mono">{PlayFeedback.next_turn(@round_summary.next_drawer_name)}</div>
          </div>
        </div>
      {/if}

      <div class="game-layout">
        <div class="panel">
          <div class="panel-head">
            <span>scores</span>
            <span class="mono">round {@round}/{@total_rounds}</span>
          </div>
          <div class="panel-body" style="padding: 0;">
            <ScoreBoard players={@players}
              drawer_id={@current_drawer && @current_drawer.id}
              guessed_ids={@correct_guessers} />
          </div>
        </div>

        <div class="canvas-shell">
          <div class="between canvas-head" style="padding: 10px 14px; border-bottom: 1px solid var(--hairline);">
            <div class="row" style="gap: 8px;">
              {%if @current_drawer}
                <Avatar avatar_id={@current_drawer.avatar_id} color={@current_drawer.avatar_color} size="xs" />
                <span style="font-size: 13px; font-weight: 500;">{@current_drawer.username}</span>
                <span class="mono" style="font-size: 11px; color: var(--muted);">is drawing</span>
              {/if}
            </div>
            <span class="mono" style="font-size: 11px; color: var(--muted);">
              {%if @is_drawer}your turn — draw the word above{%else}guess in chat →{/if}
            </span>
          </div>

          <DrawingCanvas is_drawer={@is_drawer}
            strokes={@drawing_strokes}
            active_color={if(@draw_eraser, do: "#FFFFFF", else: @draw_color)}
            active_width={if(@draw_eraser, do: 20, else: @draw_width)} />

          {%if @is_drawer}
            <div class="toolbar">
              <div class="swatches">
                {%for c <- ["#0a0a0a", "#d63838", "#2a6df4", "#1f9a4a", "#eab308", "#f97316", "#a855f7", "#ec4899"]}
                  <button class={"swatch " <> if(@draw_color == c && !@draw_eraser, do: "active", else: "")}
                          style={"background: " <> c <> ";"}
                          $click={:select_color, color: c}></button>
                {/for}
              </div>
              <div class="tool-group">
                {%for {wv, sz} <- [{2, 4}, {5, 7}, {10, 10}, {20, 14}]}
                  <button class={"tool-btn " <> if(@draw_width == wv && !@draw_eraser, do: "active", else: "")}
                          $click={:select_width, width: wv}>
                    <span class="size-dot" style={"width: " <> Integer.to_string(sz) <> "px; height: " <> Integer.to_string(sz) <> "px;"}></span>
                  </button>
                {/for}
              </div>
              <div class="tool-group">
                <button class={"tool-btn " <> if(@draw_eraser, do: "active", else: "")} $click={:toggle_eraser}>erase</button>
                <button class="tool-btn" $click={:undo_drawing}>undo</button>
                <button class="tool-btn" $click={:clear_canvas}>clear</button>
              </div>
              <span class="mono" style="font-size: 11px; color: var(--muted); margin-left: auto;">
                <span class="kbd">⌘/Ctrl+Z</span> undo · <span class="kbd">E</span> eraser
              </span>
              <window
                $key_down.e="shortcut_eraser"
                $key_down.ctrl+z.prevent_default={:shortcut_undo, via: :ctrl}
                $key_down.meta+z.prevent_default={:shortcut_undo, via: :meta} />
            </div>
          {%else}
            <div class="toolbar" style="justify-content: space-between;">
              <div class="row" style="gap: 8px;">
                <span class="chip">spectator tools are disabled</span>
              </div>
              <span class="mono" style="font-size: 11px; color: var(--muted);">
                fastest correct guess wins more points
              </span>
            </div>
          {/if}
        </div>

        <div class="panel chat-panel">
          <div class="panel-head">
            <span>chat · {length(@chat_messages)} messages</span>
            <span class="mono" style="color: var(--muted);">type to guess</span>
          </div>
          <ChatBox messages={@chat_messages} current_message={@new_message}
            current_user_id={@current_user_id} is_drawer={@is_drawer}
            rate_limited={@rate_limited} notice={@chat_notice}
            got_it={if PlayFeedback.guessed?(@correct_guessers, @current_user_id, @guess_points) do PlayFeedback.got_it(@guess_points) end}
            disabled={!@game_started or @is_drawer} />
        </div>
      </div>
    </div>
    {/if}
    {/if}
    """
  end
end
