defmodule ScrawlyWeb.Pages.PastGamesPage do
  use Hologram.Page

  route "/past-games"
  layout ScrawlyWeb.Layouts.AppLayout

  alias Hologram.UI.Link

  def init(_params, component, server) do
    user_id = get_session(server, :user_id)

    if user_id do
      results =
        case Scrawly.Games.get_game_results_for_player(user_id, load: [:room]) do
          {:ok, r} ->
            Enum.map(r, fn result ->
              %{
                game_id: result.game_id,
                score: result.score,
                room_name: if(result.room, do: result.room.name, else: "Unknown Room"),
                played_at: Calendar.strftime(result.created_at, "%b %d, %Y at %H:%M")
              }
            end)

          _ ->
            []
        end

      component
      |> put_state(:results, results)
      |> put_state(:authenticated, true)
    else
      component
      |> put_state(:results, [])
      |> put_state(:authenticated, false)
    end
  end

  def template do
    ~HOLO"""
    <div class="page page-narrow">
      <section class="hero" style="padding-bottom: 24px;">
        <div>
          <h1 style="font-size: 44px;">history.</h1>
          <p class="sub" style="margin-top: 10px;">every game you've played, oldest at the bottom.</p>
        </div>
        <div class="meta">
          <div class="section-label">summary</div>
          <div class="big">{length(@results)}</div>
          <div class="v" style="margin-top: 6px;">games</div>
        </div>
      </section>

      {%if !@authenticated}
        <div class="surface" style="padding: 32px; text-align: center;">
          <p style="color: var(--muted);">please log in to see your past games.</p>
        </div>
      {%else}
        {%if length(@results) == 0}
          <div class="surface" style="padding: 32px; text-align: center;">
            <p style="color: var(--muted);">no games played yet. go play some.</p>
          </div>
        {%else}
          <div class="section-header">
            <h2>all games</h2>
          </div>
          <div class="history">
            <div class="history-row" style="color: var(--muted); cursor: default; font-family: 'Geist Mono', monospace; font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em;">
              <span>date</span>
              <span>room</span>
              <span>game</span>
              <span></span>
              <span style="text-align: right;">score</span>
              <span></span>
            </div>
            {%for result <- @results}
              <Link to={ScrawlyWeb.Pages.GameScorePage, game_id: result.game_id}>
                <div class="history-row">
                  <span class="date">{result.played_at}</span>
                  <span class="name">{result.room_name}</span>
                  <span class="mono" style="color: var(--muted);">—</span>
                  <span class="mono" style="color: var(--ink);"></span>
                  <span class="score" style="text-align: right;">{result.score}</span>
                  <span class="arrow">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="14" height="14"><path d="M5 12h14M13 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
                  </span>
                </div>
              </Link>
            {/for}
            <div style="padding: 20px 8px; text-align: center; color: var(--muted); font-size: 12px;" class="mono">
              end of history
            </div>
          </div>
        {/if}
      {/if}
    </div>
    """
  end
end
