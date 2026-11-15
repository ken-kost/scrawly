defmodule ScrawlyWeb.Pages.PastGamesPage do
  use ScrawlyWeb.Page
  use Hologram.JS

  js_import :takeStaleRoomChannels, from: "./room_channels.mjs"

  route "/past-games"

  alias Hologram.UI.Link
  alias ScrawlyWeb.{CommandParams, RoomSubscriptions}

  def init(_params, component, server) do
    user_id = ScrawlyWeb.Auth.user_id(server)

    component =
      component
      |> put_state(:mount_id, System.unique_integer([:positive]))
      |> put_state(:page_shown?, false)

    if user_id do
      results =
        case Scrawly.Games.get_game_results_for_player(user_id,
               load: [:room, :players_in_game, :players_ahead]
             ) do
          {:ok, r} ->
            Enum.map(r, fn result ->
              %{
                game_id: result.game_id,
                score: result.score,
                room_name: if(result.room, do: result.room.name, else: "Unknown Room"),
                place: place_label(result.players_ahead + 1, result.players_in_game),
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

  @doc ~S"""
  The player's place among a game's players, e.g. `"1st of 3"` (players
  with the same score share the place).
  """
  @spec place_label(pos_integer, non_neg_integer) :: String.t()
  def place_label(place, players), do: "#{ordinal(place)} of #{max(players, place)}"

  defp ordinal(n) when rem(n, 100) in 11..13, do: "#{n}th"
  defp ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  defp ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  defp ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"

  def template do
    ~HOLO"""
    <div class="page page-narrow">
      <script>Hologram.dispatchAction("page_shown", "page", \{mount_id: "{@mount_id}"\});</script>
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
              <span>place</span>
              <span style="text-align: right;">score</span>
              <span></span>
            </div>
            {%for result <- @results}
              <Link to={ScrawlyWeb.Pages.GameScorePage, game_id: result.game_id}>
                <div class="history-row">
                  <span class="date">{result.played_at}</span>
                  <span class="name">{result.room_name}</span>
                  <span class="place mono">{result.place}</span>
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

  # The inline script dispatches :page_shown whenever this page instance's
  # markup is inserted. The second time is a Back/Forward restore: the server
  # still holds the subscriptions of the page shown before (the lobby, a
  # room), which go now (ScrawlyWeb.RoomSubscriptions).
  def action(:page_shown, _params, component) do
    # Hologram 0.12.8 keeps the put_page/2 that left this page in the
    # component it saves (only next_action and next_command are cleared), so
    # after a restore the first action to return it would navigate there again
    # (Back from a game page bounced straight back to it). Drop it.
    component = %{component | next_page: nil}

    if component.state.page_shown? do
      stale_rooms = JS.call(:takeStaleRoomChannels, [nil])

      put_command(component, :drop_stale_subscriptions,
        stale_rooms: if(is_list(stale_rooms), do: stale_rooms, else: [])
      )
    else
      put_state(component, :page_shown?, true)
    end
  end

  # ── Other pages' broadcasts ─────────────────────────────────────────
  # HomePage's `:lobby` and GamePage's room actions, which reach this page
  # after a Back/Forward restore until :drop_stale_subscriptions lands.
  # Explicit clauses, no catch-all: a new broadcast action needs one here.

  def action(:lobby_room_changed, _params, component), do: component
  def action(:lobby_room_removed, _params, component), do: component
  def action(:lobby_chat_received, _params, component), do: component
  def action(:lobby_chat_cleared, _params, component), do: component
  def action(:room_delta, _params, component), do: component
  def action(:chat_appended, _params, component), do: component
  def action(:stroke_completed, _params, component), do: component
  def action(:drawing_cleared, _params, component), do: component
  def action(:drawing_undone, _params, component), do: component
  def action(:private_state, _params, component), do: component

  # After a Back/Forward restore (:page_shown). A forged command (the module
  # is named in the request) is denied instead of raising (see
  # ScrawlyWeb.CommandParams).
  def command(:drop_stale_subscriptions, params, server),
    do: RoomSubscriptions.drop_stale(server, params)

  def command(name, _params, server), do: CommandParams.deny_unknown(server, name)
end
