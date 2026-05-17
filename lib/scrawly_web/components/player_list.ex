defmodule ScrawlyWeb.Components.PlayerList do
  use Hologram.Component

  prop :players, :list, default: []
  prop :current_drawer, :map, default: nil
  prop :current_user_id, :string, default: nil

  def template do
    ~HOLO"""
    <div class="surface" style="padding: 16px;">
      <div class="section-label" style="margin-bottom: 10px;">players · {length(@players)}</div>
      {%if length(@players) == 0}
        <div class="mono" style="font-size: 12px; color: var(--muted); text-align: center; padding: 12px;">no players yet</div>
      {%else}
        <div class="player-list">
          {%for player <- @players}
            <div class="player-row">
              <span class="av" style={"background: " <> Scrawly.Games.PlayerColor.for(player.id) <> "; color: #0a0a0a;"}>
                {String.upcase(String.slice(player.username || "?", 0..0))}
              </span>
              <span class="name">{player.username}</span>
              {%if @current_drawer && @current_drawer.id == player.id}
                <span class="chip chip-strong">drawing</span>
              {/if}
              {%if player.id == @current_user_id}
                <span class="chip chip-strong">you</span>
              {/if}
              <span class="tag">{player.score || 0}</span>
            </div>
          {/for}
        </div>
      {/if}
    </div>
    """
  end
end
