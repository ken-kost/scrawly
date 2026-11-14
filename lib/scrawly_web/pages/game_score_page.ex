defmodule ScrawlyWeb.Pages.GameScorePage do
  use Hologram.Page

  route "/game-results/:game_id"
  layout ScrawlyWeb.Layouts.AppLayout
  param :game_id, :string

  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.{GamePage, HomePage}

  @tick_ms 1_000
  @recheck_delay_ms 500
  @max_rechecks 10

  def init(%{game_id: game_id}, component, server) do
    user_id = ScrawlyWeb.Auth.user_id(server)

    results =
      case Scrawly.Games.get_game_results_for_game(game_id) do
        {:ok, r} -> Enum.sort_by(r, & &1.score, :desc)
        _ -> []
      end

    {room_id, room_name, round_details, game_date, creator_id} =
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

              drawing_strokes =
                Enum.map(rd["drawing_strokes"] || [], fn s ->
                  %{
                    path: s["path"] || "",
                    color: s["color"] || "#000000",
                    width: s["width"] || 2
                  }
                end)

              %{
                round: rd["round"],
                drawer_name: rd["drawer_name"],
                word: rd["word"],
                drawer_points: rd["drawer_points"] || 0,
                player_scores: player_scores,
                drawing_strokes: drawing_strokes
              }
            end)

          {game.room_id, rname, details, game.created_at, cid}

        _ ->
          {nil, "Unknown", [], nil, nil}
      end

    is_host = user_id != nil and user_id == creator_id

    # The countdown shows only while the room is actually in :post_game.
    countdown_ms = post_game_remaining_ms(room_id)
    room_active = countdown_ms != nil

    # Every key in every branch: the countdown actions read them all.
    component =
      component
      |> put_state(:game_id, game_id)
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

    if room_active do
      {put_action(component, :start_countdown), put_subscription(server, {:room, room_id})}
    else
      {component, server}
    end
  end

  # ms before the room returns to the lobby (View.public/1), or nil when it is
  # not running or not in :post_game.
  defp post_game_remaining_ms(nil), do: nil

  defp post_game_remaining_ms(room_id) do
    case RoomServer.get_state(room_id) do
      {:ok, %{status: :post_game} = rs} -> Map.get(rs, :post_game_remaining_ms) || 0
      _ -> nil
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
    ends_at = System.monotonic_time(:millisecond) + component.state.countdown_ms

    component
    |> put_state(:countdown_ends_at, ends_at)
    |> put_tick()
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
  def command(:countdown_finished, params, server) do
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

  def command(:leave_room, params, server),
    do: Commands.leave_room(params, server, :left_room)

  def command(:dissolve_room, params, server),
    do: Commands.dissolve_room(params, server, :room_dissolved_confirmed)

  def template do
    ~HOLO"""
    <div class="page page-narrow">
      <div class="row" style="margin-bottom: 24px;">
        <button class="app-btn app-btn-ghost app-btn-sm" $click={:go_home}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="14" height="14"><path d="M19 12H5M11 6l-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          back to rooms
        </button>
      </div>

      <section style="margin-bottom: 32px;">
        <div class="between" style="align-items: flex-end;">
          <div>
            <div class="section-label">game over · room {@room_name}</div>
            <h1 style="font-size: 48px; font-weight: 600; letter-spacing: -0.03em; margin: 6px 0 0; line-height: 1;">
              {%if length(@results) > 0}{List.first(@results).player_username} wins.{%else}game ended.{/if}
            </h1>
            {%if @game_date}
              <div class="mono" style="color: var(--muted); font-size: 13px; margin-top: 8px;">{@game_date}</div>
            {/if}
          </div>
          {%if @room_id && !@room_dissolved}
            <div class="surface" style="padding: 16px; min-width: 240px;">
              <div class="section-label">next round in</div>
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
                  <div class="row" style="gap: 6px; margin-top: 8px;">
                    <span class="chip mono">{Enum.count(round.player_scores, & &1.guessed)} guessed</span>
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
        <div class="scrim" $click={:close_drawing_modal}>
          <div class="app-modal" style="max-width: 800px;">
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
    </div>
    """
  end
end
