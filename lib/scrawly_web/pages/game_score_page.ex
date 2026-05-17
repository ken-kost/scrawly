defmodule ScrawlyWeb.Pages.GameScorePage do
  use Hologram.Page

  route "/game-results/:game_id"
  layout ScrawlyWeb.Layouts.AppLayout
  param :game_id, :string

  def init(%{game_id: game_id}, component, server) do
    user_id = get_session(server, :user_id)

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

    # Only show countdown if room is actively in post_game state
    room_active =
      if room_id do
        case Scrawly.Games.RoomServer.get_state(room_id) do
          {:ok, %{status: :post_game}} -> true
          _ -> false
        end
      else
        false
      end

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
      |> put_state(:countdown, if(room_active, do: 30, else: 0))
      |> put_state(:is_host, is_host)
      |> put_state(:room_dissolved, not room_active)

    component =
      if room_active do
        put_action(component, :start_countdown)
      else
        component
      end

    {component, server}
  end

  # ── Countdown Timer ──────────────────────────────────────────────────

  def action(:start_countdown, _params, component) do
    put_command(component, :tick,
      room_id: component.state.room_id,
      countdown: component.state.countdown
    )
  end

  def action(:tick_update, params, component) do
    new_count = params.countdown

    if new_count <= 0 do
      if component.state.room_id do
        put_page(component, ScrawlyWeb.Pages.GamePage, room_id: component.state.room_id)
      else
        put_page(component, ScrawlyWeb.Pages.HomePage)
      end
    else
      component
      |> put_state(:countdown, new_count)
      |> put_command(:tick, room_id: component.state.room_id, countdown: new_count)
    end
  end

  # ── Room Dissolution Check (non-host polling) ──────────────────────

  def action(:go_home, _params, component) do
    put_command(component, :navigate_home)
  end

  def action(:do_go_home, _params, component) do
    put_page(component, ScrawlyWeb.Pages.HomePage)
  end

  def action(:room_gone, _params, component) do
    component
    |> put_state(:countdown, 0)
    |> put_state(:room_dissolved, true)
  end

  # ── Host Controls ──────────────────────────────────────────────────

  def action(:leave_room, _params, component) do
    put_command(component, :leave_room,
      room_id: component.state.room_id,
      user_id: component.state.current_user_id
    )
  end

  def action(:left_room, _params, component) do
    put_page(component, ScrawlyWeb.Pages.HomePage)
  end

  def action(:end_room, _params, component) do
    put_command(component, :dissolve_room, room_id: component.state.room_id)
  end

  def action(:room_dissolved_confirmed, _params, component) do
    put_page(component, ScrawlyWeb.Pages.HomePage)
  end

  # ── Drawing Modal ──────────────────────────────────────────────────

  def action(:open_drawing_modal, params, component) do
    put_state(component, :modal_round, params.round)
  end

  def action(:close_drawing_modal, _params, component) do
    put_state(component, :modal_round, nil)
  end

  # ── Commands ───────────────────────────────────────────────────────

  def command(:tick, %{room_id: room_id, countdown: countdown}, server) do
    Process.sleep(1000)
    new_count = countdown - 1

    # Check if room was dissolved — stop countdown but stay on page
    if not Scrawly.Games.RoomServer.room_exists?(room_id) do
      put_action(server, :room_gone)
    else
      put_action(server, :tick_update, countdown: new_count)
    end
  end

  def command(:navigate_home, _params, server) do
    put_action(server, :do_go_home)
  end

  def command(:leave_room, %{room_id: room_id, user_id: user_id}, server) do
    Scrawly.Games.RoomServer.leave(room_id, user_id)

    if user_id do
      with {:ok, user} <- Ash.get(Scrawly.Accounts.User, user_id) do
        Scrawly.Accounts.leave_room(user)
      end
    end

    put_action(server, :left_room)
  end

  def command(:dissolve_room, %{room_id: room_id}, server) do
    Scrawly.Games.RoomServer.dissolve_room(room_id)
    Scrawly.Games.dissolve_room(room_id)
    put_action(server, :room_dissolved_confirmed)
  end

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
              <div class="bar accent"><div style={"width: " <> Integer.to_string(min(100, round(@countdown / 30 * 100))) <> "%;"}></div></div>
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
