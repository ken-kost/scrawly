defmodule ScrawlyWeb.Pages.GameScorePage do
  use ScrawlyWeb.Page
  use Hologram.JS

  js_import :noteRoomChannel, from: "./room_channels.mjs"
  js_import :takeStaleRoomChannels, from: "./room_channels.mjs"

  route "/game-results/:game_id"
  param :game_id, :string

  alias Scrawly.Games.{RoomServer, StrokeRules, WordList}
  alias ScrawlyWeb.{CommandParams, PlayFeedback, RoomSubscriptions}
  alias ScrawlyWeb.Pages.{GamePage, HomePage}

  @tick_ms 1_000
  @recheck_delay_ms 500
  @max_rechecks 10

  def init(%{game_id: game_id}, component, server) do
    user_id = ScrawlyWeb.Auth.user_id(server)

    # Plain maps only: page state reaches the browser, and a GameResult record
    # (or the DateTime below) would make it load that type's code chunks.
    results =
      case Scrawly.Games.get_game_results_for_game(game_id) do
        {:ok, r} ->
          r
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.map(
            &%{player_id: &1.player_id, player_username: &1.player_username, score: &1.score}
          )

        _ ->
          []
      end

    {found?, room_id, room_name, round_details, game_date, creator_id} =
      case Scrawly.Games.get_game_by_id(game_id) do
        {:ok, game} ->
          {rname, cid} =
            case Scrawly.Games.get_room_by_id(game.room_id) do
              {:ok, room} -> {room.name, room.creator_id}
              _ -> {"Unknown", nil}
            end

          # Normalize round_details from JSONB (string keys) to atom keys
          details =
            Enum.map(game.round_details || [], fn rd ->
              player_scores =
                Enum.map(rd["player_scores"] || [], fn ps ->
                  %{
                    id: ps["id"],
                    username: ps["username"],
                    points: ps["points"] || 0,
                    guessed: ps["guessed"] == true,
                    is_drawer: ps["is_drawer"] == true
                  }
                end)

              # Capped again here (StrokeRules.replay/1), for rows saved
              # before the room capped what it saves: this page renders
              # every round's drawing, and its state carries them too.
              {drawing_strokes, cut?} = StrokeRules.replay(rd["drawing_strokes"] || [])

              %{
                round: rd["round"],
                drawer_name: rd["drawer_name"],
                word: rd["word"],
                # Games saved before rounds had a difficulty, and AI words,
                # have none.
                difficulty: difficulty(rd["difficulty"]),
                drawer_points: rd["drawer_points"] || 0,
                player_scores: player_scores,
                drawing_strokes: drawing_strokes,
                drawing_truncated: cut? or rd["drawing_truncated"] == true
              }
            end)

          {true, game.room_id, rname, details, format_date(game.created_at), cid}

        _ ->
          {false, nil, nil, [], nil, nil}
      end

    is_host = user_id != nil and user_id == creator_id

    # The countdown back to the room shows only for the game the room has
    # just finished (in :post_game) and to one of its players
    # (countdown_ms/3).
    countdown_ms = countdown_ms(room_id, game_id, user_id)
    room_active = countdown_ms != nil

    # Every key in every branch: the countdown actions read them all.
    component =
      component
      |> put_state(:not_found?, not found?)
      |> put_state(:headline, headline(results))
      |> put_state(:results, results)
      |> put_state(:current_user_id, user_id)
      |> put_state(:room_id, room_id)
      |> put_state(:room_name, room_name)
      |> put_state(:round_details, round_details)
      |> put_state(:game_date, game_date)
      |> put_state(:modal_round, nil)
      |> put_state(:countdown_ms, countdown_ms || 0)
      |> put_state(:countdown, seconds_left(countdown_ms || 0))
      |> put_state(:countdown_total, div(RoomServer.post_game_ms(), 1000))
      |> put_state(:countdown_ends_at, nil)
      |> put_state(:lobby_ready, false)
      |> put_state(:leaving, false)
      |> put_state(:recheck_attempts, 0)
      |> put_state(:tick_gen, System.unique_integer([:positive]))
      |> put_state(:is_host, is_host)
      |> put_state(:room_dissolved, not room_active)
      # Keys the template's inline script (:page_shown) to this instance.
      |> put_state(:mount_id, System.unique_integer([:positive]))
      |> put_state(:page_shown?, false)

    if room_active do
      {put_action(component, :start_countdown), put_subscription(server, {:room, room_id})}
    else
      {component, server}
    end
  end

  # A saved round's difficulty (JSONB keeps the atom as its name), or nil.
  defp difficulty(name) when is_binary(name),
    do: Enum.find(WordList.difficulties(), &(Atom.to_string(&1) == name))

  defp difficulty(_none), do: nil

  # Same format as PastGamesPage.
  defp format_date(nil), do: nil
  defp format_date(datetime), do: Calendar.strftime(datetime, "%b %d, %Y at %H:%M")

  # The page's title: the winner, or the players who share the top score.
  defp headline([]), do: "game ended."
  defp headline([%{score: 0} | _]), do: "no one scored."

  defp headline([%{score: top} | _] = results) do
    case Enum.filter(results, &(&1.score == top)) do
      [winner] -> "#{winner.player_username} wins."
      tied -> "#{join_names(Enum.map(tied, & &1.player_username))} tie."
    end
  end

  defp join_names([a, b]), do: "#{a} and #{b}"
  defp join_names([a | rest]), do: "#{a}, #{join_names(rest)}"

  @doc """
  The ms before `room_id` returns to the lobby (`View.public/1`), when the
  score page of `game_id` counts down for `user_id`: the room is running and
  in `:post_game`, `game_id` is the game it has just finished (its
  `last_game_id`; for a room process restarted in `:post_game`, which lost
  it, the room's latest completed game) and `user_id` is one of its players.
  Otherwise nil: the page then only offers "back to home".
  """
  @spec countdown_ms(term, term, term) :: non_neg_integer | nil
  def countdown_ms(room_id, game_id, user_id)
      when is_binary(room_id) and is_binary(game_id) and is_binary(user_id) do
    with {:ok, %{status: :post_game} = rs} <- RoomServer.get_state(room_id),
         true <- Enum.any?(rs.players || [], &(&1.id == user_id)),
         true <- latest_game?(rs, game_id) do
      Map.get(rs, :post_game_remaining_ms) || 0
    else
      _ -> nil
    end
  end

  def countdown_ms(_room_id, _game_id, _user_id), do: nil

  defp latest_game?(%{last_game_id: last}, game_id) when is_binary(last), do: last == game_id

  defp latest_game?(rs, game_id) do
    case Scrawly.Games.get_games_for_room(rs.room_id) do
      {:ok, [%{id: ^game_id} | _]} -> true
      _ -> false
    end
  end

  # ── Countdown ────────────────────────────────────────────────────────
  #
  # A deadline-anchored client countdown (Hologram 0.9.2). GamePage's round
  # countdowns follow the same rules:
  #
  #   * init (server) puts every countdown key in every branch, the time left
  #     as ms from the server (never its monotonic deadline or a wall-clock
  #     time) and a `tick_gen` unique to this page instance.
  #   * :start_countdown (browser) anchors `countdown_ends_at` on the client's
  #     monotonic clock and puts the first :countdown_tick. Each tick
  #     recomputes the time left from the anchor, never decrements (background
  #     tabs throttle timers), and re-puts itself always with `delay:` (an
  #     action re-putting itself without one never yields on 0.12).
  #   * Ticks carry the gen. On 0.9.2 a delayed action or a command reply is a
  #     bare setTimeout with no page identity: one still pending when the page
  #     is left runs once on the next page. The gen check turns one that lands
  #     on another GameScorePage (or GamePage) instance into a no-op, and
  #     `leaving` / `room_dissolved` end the chain.
  #   * Navigate only from :countdown_tick, :recheck_countdown or
  #     :countdown_done, where nothing else of the chain is pending, and set
  #     `leaving` first. :room_delta only records what happened.
  #   * Go to GamePage only once the server has left :post_game (`lobby_ready`
  #     from a :room_delta, or :countdown_finished confirming it): GamePage
  #     would send a viewer of a :post_game room back here. The confirmation
  #     is retried at most @max_rechecks times, @recheck_delay_ms apart, then
  #     the page shows "back to home".

  def action(:start_countdown, _params, component) do
    JS.call(:noteRoomChannel, [component.state.room_id])
    ends_at = System.monotonic_time(:millisecond) + component.state.countdown_ms

    component
    |> put_state(:countdown_ends_at, ends_at)
    |> put_tick()
  end

  # ── Back/Forward ────────────────────────────────────────────────────
  #
  # Dispatched by the template's inline script each time this page
  # instance's markup is put into the document: on its first render, and
  # again when Back/Forward restores the page from Hologram's snapshot. A
  # restore runs neither init nor :start_countdown, its tick chain died with
  # the page it left, and the server still holds the subscriptions of the
  # page shown before. So the second time round the page asks the room again
  # (:resync_countdown): still in the post-game window for this viewer ->
  # a new chain from the room's remaining time and the room subscription
  # again (:countdown_resynced); otherwise "back to home" (:room_gone), never
  # a navigation. Either way the other pages' subscriptions go.
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

      state.room_id != nil and (not state.room_dissolved or state.leaving) ->
        gen = state.tick_gen + 1
        stale_rooms = JS.call(:takeStaleRoomChannels, [state.room_id])

        component
        |> put_state(:tick_gen, gen)
        |> put_state(:leaving, false)
        |> put_state(:lobby_ready, false)
        |> put_state(:recheck_attempts, 0)
        |> put_command(:resync_countdown,
          room_id: state.room_id,
          game_id: component.props.game_id,
          gen: gen,
          stale_rooms: list_or_empty(stale_rooms)
        )

      true ->
        stale_rooms = JS.call(:takeStaleRoomChannels, [nil])
        put_command(component, :drop_stale_subscriptions, stale_rooms: list_or_empty(stale_rooms))
    end
  end

  # Reply to :resync_countdown while the post-game window is still open.
  def action(:countdown_resynced, %{gen: gen, remaining_ms: ms}, component) do
    if gen == component.state.tick_gen and not component.state.leaving do
      component
      |> put_state(:room_dissolved, false)
      |> put_state(:countdown_ms, ms)
      |> put_state(:countdown, seconds_left(ms))
      |> put_action(:start_countdown)
    else
      component
    end
  end

  def action(:countdown_tick, %{gen: gen}, component) do
    cond do
      stale?(component, gen) ->
        component

      component.state.lobby_ready ->
        go_to_room(component)

      true ->
        now = System.monotonic_time(:millisecond)
        left_ms = max(0, component.state.countdown_ends_at - now)
        component = put_state(component, :countdown, seconds_left(left_ms))

        if left_ms > 0,
          do: put_tick(component),
          else: put_countdown_finished(component, gen)
    end
  end

  # Reply to :countdown_finished while the room is still in :post_game.
  def action(:recheck_countdown, %{gen: gen}, component) do
    cond do
      stale?(component, gen) ->
        component

      component.state.lobby_ready ->
        go_to_room(component)

      component.state.recheck_attempts >= @max_rechecks ->
        put_state(component, :room_dissolved, true)

      true ->
        component
        |> put_state(:recheck_attempts, component.state.recheck_attempts + 1)
        |> put_countdown_finished(gen)
    end
  end

  # Reply to :countdown_finished once the room has left :post_game.
  def action(:countdown_done, %{gen: gen}, component) do
    if stale?(component, gen), do: component, else: go_to_room(component)
  end

  # Reply to :countdown_finished when the room is gone or ended.
  def action(:room_gone, %{gen: gen}, component) do
    if gen == component.state.tick_gen, do: room_gone(component), else: component
  end

  # ── Room broadcasts ({:room, room_id}, subscribed while :post_game) ──
  # Only :status is read: the rest of the payload belongs to GamePage. Never
  # navigate from here (a tick may be pending). Every {:room} action needs a
  # clause here; there is deliberately no catch-all.

  def action(:room_delta, %{status: :ended}, component), do: room_gone(component)

  def action(:room_delta, %{status: :lobby}, component),
    do: put_state(component, :lobby_ready, true)

  def action(:room_delta, _params, component), do: component

  def action(:chat_appended, _params, component), do: component
  def action(:stroke_completed, _params, component), do: component
  def action(:drawing_cleared, _params, component), do: component
  def action(:drawing_undone, _params, component), do: component

  # The drawer's slice comes on GamePage's {:room_player} channel, which this
  # page never subscribes to; one pushed while the game page was being left
  # must not crash this one.
  def action(:private_state, _params, component), do: component

  # HomePage's `:lobby` actions, which reach this page when it was restored
  # by Back/Forward from the home page, until the restore's command deletes
  # that subscription (ScrawlyWeb.RoomSubscriptions).
  def action(:lobby_room_changed, _params, component), do: component
  def action(:lobby_room_removed, _params, component), do: component
  def action(:lobby_chat_received, _params, component), do: component
  def action(:lobby_chat_cleared, _params, component), do: component

  # ── Navigation ──────────────────────────────────────────────────────

  def action(:go_home, _params, component), do: leave_for_home(component)

  # ── Host Controls ──────────────────────────────────────────────────

  def action(:leave_room, _params, component) do
    put_command(component, :leave_room, room_id: component.state.room_id)
  end

  def action(:left_room, _params, component), do: leave_for_home(component)

  def action(:end_room, _params, component) do
    put_command(component, :dissolve_room, room_id: component.state.room_id)
  end

  def action(:room_dissolved_confirmed, _params, component), do: leave_for_home(component)

  # A command was rejected server-side (see ScrawlyWeb.Auth.deny/3); nothing changed.
  def action(:command_denied, _params, component), do: component

  # A GamePage stroke op acked after the game ended and this page took over.
  def action(:stroke_op_acked, _params, component), do: component

  # ── Drawing Modal ──────────────────────────────────────────────────

  def action(:open_drawing_modal, params, component) do
    put_state(component, :modal_round, params.round)
  end

  def action(:close_drawing_modal, _params, component) do
    put_state(component, :modal_round, nil)
  end

  # ── Countdown helpers (client) ─────────────────────────────────────

  defp stale?(component, gen) do
    gen != component.state.tick_gen or component.state.leaving or
      component.state.room_dissolved
  end

  defp seconds_left(ms), do: div(ms + 999, 1000)

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_other), do: []

  defp put_tick(component) do
    put_action(component,
      name: :countdown_tick,
      params: %{gen: component.state.tick_gen},
      delay: @tick_ms
    )
  end

  defp put_countdown_finished(component, gen) do
    put_command(component, :countdown_finished, room_id: component.state.room_id, gen: gen)
  end

  defp room_gone(component) do
    component
    |> put_state(:countdown, 0)
    |> put_state(:room_dissolved, true)
  end

  defp go_to_room(component) do
    component
    |> put_state(:leaving, true)
    |> put_page(GamePage, room_id: component.state.room_id)
  end

  defp leave_for_home(component) do
    component
    |> put_state(:leaving, true)
    |> put_page(HomePage)
  end

  # ── Commands ───────────────────────────────────────────────────────

  alias ScrawlyWeb.Pages.GamePage.Commands

  # Sent once the client countdown reaches zero. Replies :countdown_done when
  # the room has left :post_game (normally for :lobby), :recheck_countdown
  # (after @recheck_delay_ms) while it is still in :post_game, and :room_gone
  # when it is ended or not running. Every reply carries the tick's gen.
  def command(:countdown_finished, params, server) when is_map(params) do
    gen = Map.get(params, :gen)

    case RoomServer.get_state(Map.get(params, :room_id)) do
      {:ok, %{status: :post_game}} ->
        put_action(server,
          name: :recheck_countdown,
          params: %{gen: gen},
          delay: @recheck_delay_ms
        )

      {:ok, %{status: :ended}} ->
        put_action(server, :room_gone, gen: gen)

      {:ok, _} ->
        put_action(server, :countdown_done, gen: gen)

      {:error, _} ->
        put_action(server, :room_gone, gen: gen)
    end
  end

  # After a Back/Forward restore of a page that was counting down: replies
  # :countdown_resynced (the room's remaining ms, and the room's subscription
  # again) while countdown_ms/3 still holds for the session user, else
  # :room_gone. Drops the other pages' subscriptions either way (the room's
  # own too when it no longer counts down).
  def command(:resync_countdown, params, server) do
    with {:ok, room_id} <- CommandParams.uuid(params, :room_id),
         game_id when is_binary(game_id) <- CommandParams.string(params, :game_id) do
      gen = Map.get(params, :gen)

      case countdown_ms(room_id, game_id, ScrawlyWeb.Auth.user_id(server)) do
        nil ->
          server
          |> RoomSubscriptions.drop_stale(
            Map.update(params, :stale_rooms, [room_id], &[room_id | List.wrap(&1)])
          )
          |> put_action(:room_gone, gen: gen)

        ms ->
          server
          |> RoomSubscriptions.drop_stale(params, keep_room: room_id)
          |> put_subscription({:room, room_id})
          |> put_action(:countdown_resynced, gen: gen, remaining_ms: ms)
      end
    else
      _ -> CommandParams.deny_invalid(server, :resync_countdown)
    end
  end

  # After a Back/Forward restore of a page that wasn't counting down: drops
  # the subscriptions the page shown before left behind.
  def command(:drop_stale_subscriptions, params, server),
    do: RoomSubscriptions.drop_stale(server, params)

  # Shape-checked like GamePage's room commands; malformed params and unknown
  # names are denied, never raised on.
  def command(name, params, server) when name in [:leave_room, :dissolve_room] do
    case Commands.valid_params(name, params) do
      {:ok, params} when name == :leave_room ->
        Commands.leave_room(params, server, :left_room)

      {:ok, params} ->
        Commands.dissolve_room(params, server, :room_dissolved_confirmed)

      :error ->
        ScrawlyWeb.CommandParams.deny_invalid(server, name)
    end
  end

  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)

  def template do
    ~HOLO"""
    <div class="page page-narrow">
      <script>Hologram.dispatchAction("page_shown", "page", \{mount_id: "{@mount_id}"\});</script>
      {%if @not_found?}
      <div class="row" style="margin-bottom: 24px;">
        <button class="app-btn app-btn-ghost app-btn-sm" $click={:go_home}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="14" height="14"><path d="M19 12H5M11 6l-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          back to rooms
        </button>
      </div>
      <section class="surface" style="padding: 32px; text-align: center;">
        <h1 style="font-size: 28px; font-weight: 600; margin: 0 0 8px;">game not found.</h1>
        <p style="color: var(--muted); margin: 0;">there are no results for this game. it may never have finished.</p>
      </section>
      {%else}
      <div class="row" style="margin-bottom: 24px;">
        <button class="app-btn app-btn-ghost app-btn-sm" $click={:go_home}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="14" height="14"><path d="M19 12H5M11 6l-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          back to rooms
        </button>
      </div>

      <section style="margin-bottom: 32px;">
        <div class="between score-head" style="align-items: flex-end;">
          <div class="score-title">
            <div class="section-label">game over · room {@room_name}</div>
            <h1 class="score-headline">{@headline}</h1>
            {%if @game_date}
              <div class="mono" style="color: var(--muted); font-size: 13px; margin-top: 8px;">{@game_date}</div>
            {/if}
          </div>
          {%if @room_id && !@room_dissolved}
            <div class="surface score-countdown" style="padding: 16px; min-width: 240px;">
              <div class="section-label">back to the lobby in</div>
              <div class="timer-big mono" style="font-size: 36px; margin: 6px 0;">{@countdown}s</div>
              <div class="bar accent"><div style={"width: " <> Integer.to_string(min(100, round(@countdown / @countdown_total * 100))) <> "%;"}></div></div>
              <div class="row" style="gap: 8px; margin-top: 12px;">
                {%if @is_host}
                  <button class="app-btn app-btn-primary app-btn-sm" style="flex: 1;" $click={:end_room}>end room</button>
                {/if}
                <button class="app-btn app-btn-sm" $click={:leave_room}>leave</button>
              </div>
            </div>
          {%else}
            <div>
              <button class="app-btn app-btn-primary" $click={:go_home}>back to home</button>
            </div>
          {/if}
        </div>
      </section>

      <section style="margin-bottom: 48px;">
        <div class="section-header">
          <h2>final standings</h2>
          <span class="mono" style="font-size: 11px; color: var(--muted);">{length(@results)} player(s)</span>
        </div>
        <div class="standings">
          {%for {result, i} <- Enum.with_index(@results)}
            <div class={"stand-row " <> if(i == 0, do: "winner", else: "")}>
              <span class="rank">{String.pad_leading(Integer.to_string(i + 1), 2, "0")}</span>
              <span class="who">
                {result.player_username}
                {%if result.player_id == @current_user_id}<span class="chip chip-strong" style="margin-left: 8px;">you</span>{/if}
              </span>
              <span class="delta mono"></span>
              <span class="pts">{result.score}</span>
            </div>
          {/for}
          {%if length(@results) == 0}
            <div style="padding: 32px; text-align: center; color: var(--muted);">no results recorded</div>
          {/if}
        </div>
      </section>

      {%if length(@round_details) > 0}
        <section>
          <div class="section-header">
            <h2>round-by-round</h2>
            <span class="mono" style="font-size: 11px; color: var(--muted);">click a drawing to enlarge</span>
          </div>
          <div class="rounds-list">
            {%for round <- @round_details}
              <div class="round-card">
                <div class="thumb" $click={:open_drawing_modal, round: round.round}>
                  <svg viewBox="0 0 800 450" preserveAspectRatio="xMidYMid meet">
                    {%for stroke <- round.drawing_strokes}
                      <path d={stroke.path} stroke={stroke.color} stroke-width={stroke.width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
                    {/for}
                  </svg>
                </div>
                <div class="round-meta">
                  <div class="section-label">round {round.round}</div>
                  <div class="word">{String.upcase(round.word || "")}</div>
                  <div class="by">drawn by <span style="color: var(--ink);">{round.drawer_name}</span></div>
                  <div class="row" style="gap: 6px; margin-top: 8px; flex-wrap: wrap;">
                    {%if round.difficulty}<span class={PlayFeedback.difficulty_class(round.difficulty)}>{PlayFeedback.difficulty_label(round.difficulty)}</span>{/if}
                    <span class="chip mono">{Enum.count(round.player_scores, & &1.guessed)} guessed</span>
                    {%if round.drawing_truncated}<span class="chip mono" title="long drawings are kept up to a size limit">drawing trimmed</span>{/if}
                  </div>
                </div>
                <div class="round-scores">
                  <div class="section-label" style="margin-bottom: 4px;">points</div>
                  {%for ps <- round.player_scores}
                    <div class="ln">
                      <span>{ps.username}</span>
                      <span class={cond do ps.points > 0 -> "pos"; ps.points < 0 -> "neg"; true -> "" end}>
                        {%if ps.points > 0}+{ps.points}{%else}{ps.points}{/if}
                      </span>
                    </div>
                  {/for}
                </div>
              </div>
            {/for}
          </div>
        </section>
      {/if}

      {%if @modal_round}
        <window $key_down.escape="close_drawing_modal" />
        <div class="scrim">
          <div class="app-modal" style="max-width: 800px;" $click_outside={:close_drawing_modal}>
            {%for round <- @round_details}
              {%if round.round == @modal_round}
                <div class="app-modal-head">
                  <div>
                    <h3>round {round.round}: {round.word}</h3>
                    <div class="sub">drawn by {round.drawer_name}</div>
                  </div>
                  <button type="button" class="icon-btn" $click={:close_drawing_modal}>
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M6 6l12 12M18 6L6 18" stroke-linecap="round"/></svg>
                  </button>
                </div>
                <div style="padding: 20px;">
                  <div style="background: #fff; border: 1px solid var(--hairline); border-radius: 6px; overflow: hidden;">
                    <svg viewBox="0 0 800 450" preserveAspectRatio="xMidYMid meet" style="width: 100%; display: block;">
                      {%for stroke <- round.drawing_strokes}
                        <path d={stroke.path} stroke={stroke.color} stroke-width={stroke.width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
                      {/for}
                    </svg>
                  </div>
                </div>
              {/if}
            {/for}
          </div>
        </div>
      {/if}
      {/if}
    </div>
    """
  end
end
