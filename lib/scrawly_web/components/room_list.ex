defmodule ScrawlyWeb.Components.RoomList do
  use Hologram.Component

  prop :rooms, :list, default: []
  prop :loading, :boolean, default: false

  def template do
    ~HOLO"""
    <div class="room-list">
      {%if length(@rooms) == 0}
        <div style="padding: 56px 16px; text-align: center; color: var(--muted);">
          <h3 style="color: var(--ink); font-size: 16px; font-weight: 500; margin: 0 0 6px;">no rooms yet</h3>
          <p style="font-size: 13px;">create one to get started.</p>
        </div>
      {%else}
        {%for {room, idx} <- Enum.with_index(@rooms)}
          <div class="room-row" $click={:join_room, room_id: room.room_id}>
            <span class="room-num mono">{String.pad_leading(Integer.to_string(idx + 1), 2, "0")}</span>
            <div class="room-title">
              <span class="name">{room.name}</span>
              <span class="meta">
                <span>[{Map.get(room, :code, "") || ""}]</span>
                <span>[{if((Map.get(room, :word_source, :local) || :local) == :ai, do: "ai", else: "local")}]</span>
                <span>{Map.get(room, :round_duration, 60) || 60}s × {Map.get(room, :round_multiplier, 1) || 1}r</span>
              </span>
            </div>
            <div class="avatar-stack">
              {%for {p, _i} <- Enum.with_index(Enum.take(room.players, 4))}
                <span class="avatar" style={"background: " <> Scrawly.Games.PlayerColor.for(p.id) <> "; color: #0a0a0a;"}>{String.upcase(String.slice(p.username || "?", 0..0))}</span>
              {/for}
              {%if length(room.players) > 4}
                <span class="avatar" style="background: transparent; color: var(--muted);">+{length(room.players) - 4}</span>
              {/if}
            </div>
            <span class="mono" style="font-size: 12px; color: var(--muted); min-width: 60px; text-align: right;">
              {length(room.players)}/{room.max_players}
            </span>
            {%if length(room.players) >= room.max_players}
              <span class="chip chip-strong">full</span>
            {%else}
              <span class="chip chip-strong">lobby</span>
            {/if}
          </div>
        {/for}
        <div style="padding: 16px 8px; color: var(--muted); font-size: 12px;" class="mono">
          showing {length(@rooms)} room(s)
        </div>
      {/if}
    </div>
    """
  end
end
