defmodule ScrawlyWeb.Pages.GamePage do
  use Hologram.Page
  use Hologram.JS

  js_import :connectGameChannel, from: "./game_channel.mjs"
  js_import :pushDrawingSegment, from: "./game_channel.mjs"
  js_import :pushDrawingClear, from: "./game_channel.mjs"

  # JS-managed drawing — bypasses Hologram re-renders for smooth drawing
  js_import :startStroke, from: "./drawing_manager.mjs"
  js_import :continueStroke, from: "./drawing_manager.mjs"
  js_import :endStroke, from: "./drawing_manager.mjs"
  js_import :clearDrawing, from: "./drawing_manager.mjs"
  js_import :setDrawingPath, from: "./drawing_manager.mjs"
  js_import :getDrawingPath, from: "./drawing_manager.mjs"
  js_import :resetSentLength, from: "./drawing_manager.mjs"
  js_import :setToolColor, from: "./drawing_manager.mjs"
  js_import :setToolWidth, from: "./drawing_manager.mjs"
  js_import :undoStroke, from: "./drawing_manager.mjs"
  js_import :setStrokes, from: "./drawing_manager.mjs"

  route "/game/:room_id"
  layout ScrawlyWeb.Layouts.AppLayout
  param :room_id, :string

  alias ScrawlyWeb.Components.{ChatBox, ScoreBoard, DrawingCanvas}
  alias Scrawly.Games.{WordHints, RoomServer}
  # Note: WordHints is used ONLY in server-side commands (poll_room_state),
  # never in client-side actions (Hologram can't compile it to JS).

  # ── Init ─────────────────────────────────────────────────────────────

  def init(%{room_id: room_id}, component, server) do
    watch_mode = get_session(server, :watch_mode) == "yes"

    case RoomServer.ensure_started(room_id) do
      {:ok, _pid} ->
        case RoomServer.get_state(room_id) do
          {:ok, rs} ->
            user_id = get_session(server, :user_id)
            is_creator = user_id == rs.creator_id
            game_active = rs.game_id != nil
            is_drawer = rs.current_drawer_id == user_id

            component =
              component
              |> put_state(:watching?, user_id == "Watcher")
              |> put_state(:room_id, room_id)
              |> put_state(:room_code, rs.code)
              |> put_state(:room_name, "Room #{rs.name}")
              |> put_state(:room_status, rs.status)
              |> put_state(:players, rs.players)
              |> put_state(:max_players, rs.max_players)
              |> put_state(:is_creator, is_creator)
              |> put_state(:creator_id, rs.creator_id)
              |> put_state(:version, rs.version)
              |> put_state(:current_user_id, user_id)
              |> put_state(:current_user_username, "")
              |> put_state(:new_message, "")
              |> put_state(:rate_limited, false)
              |> put_state(:message_timestamps, [])
              # Game state from RoomServer
              |> put_state(:game_id, rs.game_id || "")
              |> put_state(:game_started, game_active)
              |> put_state(:round, rs.current_round)
              |> put_state(:total_rounds, rs.total_rounds)
              |> put_state(:time_left, rs.time_left)
              |> put_state(
                :current_drawer,
                if(rs.current_drawer_id,
                  do: %{
                    id: rs.current_drawer_id,
                    username:
                      (Enum.find(rs.players, &(&1.id == rs.current_drawer_id)) ||
                         %{username: "Unknown"}).username
                  },
                  else: nil
                )
              )
              |> put_state(:current_word, if(game_active, do: rs.current_word, else: ""))
              |> put_state(
                :current_word_display,
                if(game_active && !is_drawer,
                  do: WordHints.hidden_display(rs.current_word || "", rs.round_duration || 60),
                  else: ""
                )
              )
              |> put_state(:is_drawer, is_drawer)
              |> put_state(:correct_guessers, rs.correct_guessers || [])
              |> put_state(:used_words, [])
              |> put_state(
                :can_start_game,
                is_creator and length(rs.players) >= 2 and rs.game_id == nil
              )
              # Shared chat & drawing from RoomServer
              |> put_state(:chat_messages, rs.chat_messages || [])
              |> put_state(:drawing_strokes, rs.drawing_strokes || [])
              |> put_state(:drawing?, false)
              |> put_state(:draw_color, "#000000")
              |> put_state(:draw_width, 2)
              |> put_state(:draw_eraser, false)
              |> put_state(:leaving?, false)
              |> put_state(:watchers, rs.watchers || [])
              # Room settings
              |> put_state(:word_count, rs.word_count || 1)
              |> put_state(:word_source, rs.word_source || :local)
              |> put_state(:prompt, rs.prompt || "")
              |> put_state(:creator_name, rs.creator_name || "")
              |> put_state(:round_duration, rs.round_duration || 60)
              |> put_state(:round_multiplier, rs.round_multiplier || 1)
              |> put_state(:ai_tone, rs.ai_tone || :fun)
              # Channel state for real-time drawing
              |> put_state(:socket_token, get_session(server, :user_token) || "")
              |> put_state(:channel_connected, false)
              # Past games history (from RoomServer state)
              |> put_state(:past_games, rs.past_games || [])
              |> load_user_data(user_id)

            already_watching =
              user_id != nil and Enum.any?(rs.watchers || [], &(&1.id == user_id))

            # Clear the one-shot watch_mode flag from session
            server = put_session(server, :watch_mode, nil)

            component =
              cond do
                # Room is in post-game cooldown — redirect to score page
                rs.status == :post_game and rs.last_game_id != nil ->
                  put_page(component, ScrawlyWeb.Pages.GameScorePage, game_id: rs.last_game_id)

                # User explicitly chose to watch, or is already a watcher
                watch_mode or already_watching ->
                  component
                  |> put_state(:watching?, true)
                  |> put_action(:do_join_as_watcher)

                # No user session — watch only
                user_id == nil ->
                  component
                  |> put_state(:watching?, true)
                  |> put_action(:do_join_as_watcher)

                # Already in the room as player — one-shot sync, then channel takes over
                Enum.any?(rs.players, &(&1.id == user_id)) ->
                  put_action(component, name: :poll_room, delay: 500)

                # Room in lobby and not full — join as player
                rs.status == :lobby and length(rs.players) < rs.max_players ->
                  put_action(component, :do_join_room)

                # Room is full or not in lobby — watch only
                true ->
                  component
                  |> put_state(:watching?, true)
                  |> put_action(:do_join_as_watcher)
              end

            {component, server}

          {:error, _} ->
            put_page(component, ScrawlyWeb.Pages.HomePage)
        end

      {:error, _} ->
        put_page(component, ScrawlyWeb.Pages.HomePage)
    end
  end

  defp load_user_data(component, "Watcher") do
    put_state(component, :current_user_username, "Watcher")
  end

  defp load_user_data(component, user_id) do
    case Ash.get(Scrawly.Accounts.User, user_id) do
      {:ok, user} ->
        put_state(component, :current_user_username, user.username)

      {:error, _} ->
        component
    end
  end

  # ── Client-side Actions: Lifecycle ───────────────────────────────────
  # Two paths for state updates:
  #   1. Channel push (primary): channel pushes full state → channel_state_update action
  #   2. Command fallback (initial sync + watchers): poll_room → poll_room_state → room_refreshed

  def action(:do_join_room, _params, component) do
    put_command(component, :join_room,
      room_id: component.state.room_id,
      user_id: component.state.current_user_id
    )
  end

  # Step 1: delayed action fires → send command to server (pass user_id so server can compute per-user fields)
  def action(:poll_room, _params, component) do
    if component.state.leaving? do
      component
    else
      put_command(component, :poll_room_state,
        room_id: component.state.room_id,
        user_id: component.state.current_user_id
      )
    end
  end

  # Used for initial state sync. Only reschedules polling for unauthenticated
  # watchers who can't use the channel. All other users get push updates.
  def action(:room_refreshed, params, component) do
    if component.state.leaving? do
      component
    else
      old_started = component.state.game_started
      new_game_active = params.game_id != nil

      cond do
        # Room ended (creator left / dissolved)
        params.status == :ended and not old_started ->
          component
          |> put_state(:chat_messages, params.chat_messages || [])
          |> put_action(name: :go_home, delay: 2000)

        # Game just ended → redirect to score page (post_game state)
        params.status == :post_game and params.last_game_id != nil ->
          put_page(component, ScrawlyWeb.Pages.GameScorePage, game_id: params.last_game_id)

        # Game just ended (fallback) → redirect to score page
        old_started and not new_game_active and params.last_game_id != nil ->
          put_page(component, ScrawlyWeb.Pages.GameScorePage, game_id: params.last_game_id)

        # Normal state update
        true ->
          component =
            component
            |> handle_game_state_changes(params)
            |> put_state(:players, params.players)
            |> put_state(:max_players, params.max_players)
            |> put_state(:room_status, params.status)
            |> put_state(:version, params.version)
            |> put_state(:correct_guessers, params.correct_guessers || [])
            |> put_state(
              :can_start_game,
              component.state.is_creator and length(params.players) >= 2 and params.game_id == nil
            )
            |> put_state(:chat_messages, params.chat_messages || [])
            |> put_state(:watchers, params.watchers || [])
            |> put_state(:past_games, params.past_games || [])
            |> sync_drawing_path(params)
            |> maybe_connect_channel()

          # Only unauthenticated watchers (no token) need polling fallback
          has_token = Map.get(component.state, :socket_token, "") != ""

          if has_token do
            component
          else
            put_action(component, name: :poll_room, delay: 3000)
          end
      end
    end
  end

  def action(:do_join_as_watcher, _params, component) do
    put_command(component, :join_as_watcher,
      room_id: component.state.room_id,
      user_id: component.state.current_user_id,
      username: component.state.current_user_username
    )
  end

  def action(:switch_to_watcher, _params, component) do
    component
    |> put_state(:watching?, true)
    |> put_action(:do_join_as_watcher)
  end

  def action(:leave_room, _params, component) do
    if component.state.watching? do
      component
      |> put_state(:leaving?, true)
      |> put_command(:leave_watcher,
        room_id: component.state.room_id,
        watcher_id: component.state.current_user_id
      )
    else
      component
      |> put_state(:leaving?, true)
      |> put_command(:leave_room,
        user_id: component.state.current_user_id,
        room_id: component.state.room_id,
        is_creator: component.state.is_creator
      )
    end
  end

  def action(:room_dissolved, _params, component) do
    put_action(component, name: :go_home, delay: 1000)
  end

  def action(:go_home, _params, component) do
    put_page(component, ScrawlyWeb.Pages.HomePage)
  end

  def action(:past_games_loaded, %{games: games}, component) do
    put_state(component, :past_games, games)
  end

  # ── Client-side Actions: Chat ────────────────────────────────────────

  def action(:send_message, _params, component) do
    # Drawer cannot send chat (prevents leaking the word)
    if component.state.is_drawer do
      put_state(component, :new_message, "")
    else
      if component.state.rate_limited do
        component
      else
        message = component.state.new_message
        now = System.monotonic_time(:millisecond)
        recent = Enum.filter(component.state.message_timestamps, fn ts -> now - ts < 5_000 end)

        if length(recent) >= 3 do
          component
          |> put_state(:rate_limited, true)
          |> put_state(:message_timestamps, recent)
          |> put_action(name: :clear_rate_limit, delay: 3_000)
        else
          if String.trim(message) != "" do
            handle_chat_message(component, message, now, recent)
          else
            component
          end
        end
      end
    end
  end

  def action(:clear_rate_limit, _params, component),
    do: put_state(component, :rate_limited, false)

  def action(:update_message, %{event: %{value: msg}}, component),
    do: put_state(component, :new_message, msg)

  def action(:scroll_chat, _params, component) do
    JS.exec(~JS"""
      var el = document.getElementById('chat-messages');
      if (el) { el.scrollTop = el.scrollHeight; }
    """)

    component
  end

  # ── Client-side Actions: Channel Events ─────────────────────────────
  # Received from Phoenix Channel broadcasts via JS interop.

  # Dispatched by JS once the channel WebSocket is actually connected.
  # Immediately poll to sync state — the join broadcast may have fired
  # before the channel was ready, so the joining user could have stale data.
  def action(:channel_connected, _params, component) do
    component
    |> put_state(:channel_connected, true)
    |> put_action(:poll_room)
  end

  # Received from channel broadcast when another player draws a stroke
  def action(:receive_drawing_stroke, params, component) do
    if not component.state.is_drawer do
      stroke = %{
        path: params.path || "",
        color: params.color || "#000000",
        width: params.width || 2
      }

      strokes = Map.get(component.state, :drawing_strokes, [])
      put_state(component, :drawing_strokes, strokes ++ [stroke])
    else
      component
    end
  end

  # Legacy: receive_drawing_segment (backward compat from old channel)
  def action(:receive_drawing_segment, params, component) do
    if not component.state.is_drawer do
      stroke = %{path: params.segment || "", color: "#000000", width: 2}
      strokes = Map.get(component.state, :drawing_strokes, [])
      put_state(component, :drawing_strokes, strokes ++ [stroke])
    else
      component
    end
  end

  # Received from channel broadcast when drawer clears canvas
  def action(:receive_drawing_clear, _params, component) do
    JS.call(:setDrawingPath, [""])
    put_state(component, :drawing_strokes, [])
  end

  # Received from channel on undo
  def action(:receive_drawing_undo, params, component) do
    if not component.state.is_drawer do
      strokes = params.strokes || []
      JS.call(:setStrokes, [strokes])
      put_state(component, :drawing_strokes, strokes)
    else
      component
    end
  end

  # Received on channel join — full strokes sync for late joiners
  def action(:sync_full_drawing_path, params, component) do
    if not component.state.is_drawer do
      strokes = params.strokes || []
      JS.call(:setStrokes, [strokes])
      put_state(component, :drawing_strokes, strokes)
    else
      component
    end
  end

  # ── Client-side Actions: Drawing ─────────────────────────────────────

  def action(:canvas_pointer_down, params, component) do
    if component.state.is_drawer and component.state.game_started and
         component.state.time_left > 0 do
      JS.call(:startStroke, [params.event.offset_x, params.event.offset_y])
      put_state(component, :drawing?, true)
    else
      component
    end
  end

  def action(:canvas_pointer_move, params, component) do
    if component.state.drawing? do
      JS.call(:continueStroke, [params.event.offset_x, params.event.offset_y])
      component
    else
      component
    end
  end

  def action(:canvas_pointer_up, _params, component) do
    if component.state.drawing? do
      JS.call(:endStroke, [])
      put_state(component, :drawing?, false)
    else
      component
    end
  end

  def action(:clear_canvas, _params, component) do
    JS.call(:clearDrawing, [])
    put_state(component, :drawing_strokes, [])
  end

  # ── Drawing tool actions ─────────────────────────────────────────────

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

  def action(:toggle_eraser, _params, component) do
    is_eraser = not Map.get(component.state, :draw_eraser, false)

    if is_eraser do
      JS.call(:setToolColor, ["#FFFFFF"])
      JS.call(:setToolWidth, [20])
    else
      JS.call(:setToolColor, [component.state.draw_color])
      JS.call(:setToolWidth, [component.state.draw_width])
    end

    put_state(component, :draw_eraser, is_eraser)
  end

  def action(:undo_drawing, _params, component) do
    JS.call(:undoStroke, [])
    component
  end

  alias ScrawlyWeb.Pages.GamePage.Commands

  # ── Server-side Commands ─────────────────────────────────────────────
  # Logic lives in GamePage.Commands to keep this module focused on UI/actions.

  def command(:poll_room_state, params, server), do: Commands.poll_room_state(params, server)
  def command(:join_room, params, server), do: Commands.join_room(params, server)
  def command(:join_as_watcher, params, server), do: Commands.join_as_watcher(params, server)
  def command(:leave_watcher, params, server), do: Commands.leave_watcher(params, server)
  def command(:start_game, params, server), do: Commands.start_game(params, server)
  def command(:end_game, params, server), do: Commands.end_game(params, server)
  def command(:leave_room, params, server), do: Commands.leave_room(params, server)
  def command(:send_chat_message, params, server), do: Commands.send_chat_message(params, server)

  def command(:record_correct_guess, params, server),
    do: Commands.record_correct_guess(params, server)

  def command(:fetch_past_games, params, server),
    do: Commands.fetch_past_games(params, server)

  # ── Private: Game State Changes ──────────────────────────────────────
  # ALL fields used here are pre-computed by the server command (poll_room_state).
  # No WordHints or complex Elixir calls — those can't run in the browser.

  defp handle_game_state_changes(component, params) do
    old_started = component.state.game_started
    new_game_active = params.game_id != nil
    old_round = component.state.round
    new_round = params.current_round || 0
    new_time = params.time_left || 0

    # Pre-computed by server
    is_drawer = params.is_drawer || false
    word_display = params.current_word_display || ""
    drawer_name = params.drawer_name || "Unknown"

    cond do
      # Game just started
      not old_started and new_game_active and (params.round_active || false) ->
        JS.call(:setDrawingPath, [""])

        component
        |> put_state(:game_started, true)
        |> put_state(:game_id, params.game_id)
        |> put_state(:round, new_round)
        |> put_state(:total_rounds, params.total_rounds || 5)
        |> put_state(:current_drawer, %{id: params.current_drawer_id, username: drawer_name})
        |> put_state(:current_word, params.current_word)
        |> put_state(:current_word_display, word_display)
        |> put_state(:is_drawer, is_drawer)
        |> put_state(:time_left, new_time)
        |> put_state(:drawing_strokes, [])

      # Game ended
      old_started and not new_game_active ->
        JS.call(:setDrawingPath, [""])

        component
        |> put_state(:game_started, false)
        |> put_state(:game_id, nil)
        |> put_state(:current_drawer, nil)
        |> put_state(:current_word, nil)
        |> put_state(:current_word_display, "")
        |> put_state(:time_left, 0)
        |> put_state(:is_drawer, false)
        |> put_state(:correct_guessers, [])
        |> put_state(:drawing_strokes, [])

      # New round
      old_started and new_round > old_round ->
        JS.call(:setDrawingPath, [""])

        component
        |> put_state(:round, new_round)
        |> put_state(:current_drawer, %{id: params.current_drawer_id, username: drawer_name})
        |> put_state(:current_word, params.current_word)
        |> put_state(:current_word_display, word_display)
        |> put_state(:is_drawer, is_drawer)
        |> put_state(:time_left, new_time)
        |> put_state(:drawing_strokes, [])

      # Timer tick or other update — always sync display from server
      old_started ->
        component
        |> put_state(:time_left, new_time)
        |> put_state(:current_word_display, word_display)
        |> put_state(:is_drawer, is_drawer)

      true ->
        component
    end
  end

  defp maybe_connect_channel(component) do
    connected = Map.get(component.state, :channel_connected, false)
    connecting = Map.get(component.state, :channel_connecting, false)
    token = Map.get(component.state, :socket_token, "")
    room_code = component.state.room_code

    if not connected and not connecting and token != "" and room_code != nil do
      JS.call(:connectGameChannel, [token, room_code])
      # Don't set channel_connected yet — wait for JS callback confirmation.
      # Polling continues until the channel_connected action fires.
      put_state(component, :channel_connecting, true)
    else
      component
    end
  end

  defp sync_drawing_path(component, params) do
    channel_connected = Map.get(component.state, :channel_connected, false)

    cond do
      params.is_drawer ->
        component

      channel_connected ->
        server_strokes = params.drawing_strokes || []
        local_strokes = Map.get(component.state, :drawing_strokes, [])

        if length(server_strokes) > length(local_strokes) do
          put_state(component, :drawing_strokes, server_strokes)
        else
          component
        end

      true ->
        put_state(component, :drawing_strokes, params.drawing_strokes || [])
    end
  end

  # ── Private: Chat ────────────────────────────────────────────────────

  defp handle_chat_message(component, message, now, recent_timestamps) do
    player_name = Map.get(component.state, :current_user_username, "You")
    current_user_id = component.state.current_user_id
    current_word = component.state.current_word
    correct_guessers = Map.get(component.state, :correct_guessers, [])
    already_guessed = current_user_id in correct_guessers

    is_correct =
      not already_guessed and
        current_word != nil and current_word != "" and
        guess_matches?(message, current_word)

    if is_correct do
      handle_correct_guess(component, player_name, current_user_id, now, recent_timestamps)
    else
      handle_regular_message(
        component,
        message,
        player_name,
        already_guessed,
        current_word,
        now,
        recent_timestamps
      )
    end
  end

  defp handle_correct_guess(component, player_name, current_user_id, now, recent_timestamps) do
    time_left = component.state.time_left
    points = calculate_points(time_left)

    # Send guess info to server — server creates the system message
    component
    |> put_state(:new_message, "")
    |> put_state(:correct_guessers, [
      current_user_id | Map.get(component.state, :correct_guessers, [])
    ])
    |> put_state(:message_timestamps, [now | recent_timestamps])
    |> put_command(:record_correct_guess,
      room_id: component.state.room_id,
      player_id: current_user_id,
      player_name: player_name,
      points: points
    )
  end

  defp handle_regular_message(
         component,
         message,
         player_name,
         _already_guessed,
         _current_word,
         now,
         recent_timestamps
       ) do
    # Send message to server — server stores it. Keep type simple (:chat).
    # Close guess detection removed from client (levenshtein not Hologram-safe).
    chat_msg = %{
      player_name: player_name,
      message: message,
      type: :chat
    }

    component
    |> put_state(:new_message, "")
    |> put_state(:message_timestamps, [now | recent_timestamps])
    |> put_command(:send_chat_message, room_id: component.state.room_id, message: chat_msg)
  end

  # ── Private: Helpers ─────────────────────────────────────────────────

  defp guess_matches?(guess, word) do
    String.downcase(String.trim(guess)) == String.downcase(String.trim(word))
  end

  # Client-side estimate — server recalculates authoritatively via Scoring module
  defp calculate_points(time_left) when is_integer(time_left) and time_left > 0, do: time_left
  defp calculate_points(_), do: 0

  # ── Template ─────────────────────────────────────────────────────────

  def template do
    ~HOLO"""
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

          <div class="lobby-code" style="margin-bottom: 24px;">
            <span class="label">code</span>
            <span class="code">{@room_code}</span>
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
                      disabled={!@can_start_game}
                      $click={command: :start_game, params: %{room_id: @room_id, players: @players}}>
                {%if @can_start_game}start game{%else}need 2+ players{/if}
              </button>
            {/if}
            <button class="app-btn app-btn-lg" $click={:leave_room}>leave</button>
          </div>
          <div class="mono" style="font-size: 11px; color: var(--muted); margin-top: 10px; text-align: center;">
            share the code to invite friends
          </div>
        </div>

        <div>
          <div class="surface" style="overflow: hidden;">
            <div class="panel-head">settings</div>
            <div class="spec-grid">
              <div class="spec"><div class="k">word source</div><div class="v">[{if(@word_source == :ai, do: "ai", else: "local")}]</div></div>
              <div class="spec"><div class="k">words / round</div><div class="v">{@word_count}</div></div>
              <div class="spec"><div class="k">duration</div><div class="v">{@round_duration}s</div></div>
              <div class="spec"><div class="k">rounds / player</div><div class="v">{@round_multiplier}×</div></div>
              {%if @prompt != "" && @prompt != nil}
                <div class="spec" style="grid-column: 1 / -1; border-right: 0;">
                  <div class="k">prompt</div>
                  <div class="v" style="font-size: 14px; color: var(--ink-2);">{@prompt}</div>
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
                  <span class="chip">
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
            <div class="word-letters">
              {%if @is_drawer && @current_word}
                {String.upcase(@current_word)}
              {%else}
                {%if @current_word_display}{@current_word_display}{%else}_ _ _{/if}
              {/if}
            </div>
            <div class="word-meta">
              {%if @is_drawer}your word · {String.length(@current_word || "")} letters{%else}round {@round} of {@total_rounds} · {String.length(@current_word || "")} letters{/if}
            </div>
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
              <div class="timer timer-big mono">{@time_left}s</div>
              <div class="bar accent" style="width: 80px;"><div style={"width: " <> Integer.to_string(min(100, round((@time_left / max(@round_duration, 1)) * 100))) <> "%;"}></div></div>
            </div>
          </div>
        </div>
      </div>

      <div class="game-layout">
        <div class="panel">
          <div class="panel-head">
            <span>scores</span>
            <span class="mono">round {@round}/{@total_rounds}</span>
          </div>
          <div class="panel-body" style="padding: 0;">
            <ScoreBoard players={@players} current_round={@round} total_rounds={@total_rounds}
                        current_word={@current_word_display} time_left={@time_left} game_status={@room_status} />
          </div>
        </div>

        <div class="canvas-shell">
          <div class="between" style="padding: 10px 14px; border-bottom: 1px solid var(--hairline);">
            <div class="row" style="gap: 8px;">
              {%if @current_drawer}
                <span class="avatar" style={"width: 22px; height: 22px; border-radius: 999px; background: " <> Scrawly.Games.PlayerColor.for(@current_drawer.id) <> "; color: #0a0a0a; display: grid; place-items: center; font-size: 11px; font-weight: 600;"}>
                  {String.upcase(String.slice(@current_drawer.username || "?", 0..0))}
                </span>
                <span style="font-size: 13px; font-weight: 500;">{@current_drawer.username}</span>
                <span class="mono" style="font-size: 11px; color: var(--muted);">is drawing</span>
              {/if}
            </div>
            <span class="mono" style="font-size: 11px; color: var(--muted);">
              {%if @is_drawer}your turn — draw the word above{%else}guess in chat →{/if}
            </span>
          </div>

          <DrawingCanvas room_id={@room_id} is_drawer={@is_drawer}
            disabled={!@game_started or @time_left == 0}
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
                <span class="kbd">U</span> undo · <span class="kbd">C</span> clear
              </span>
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
            rate_limited={@rate_limited} disabled={!@game_started or @is_drawer} />
        </div>
      </div>
    </div>
    {/if}
    """
  end
end
