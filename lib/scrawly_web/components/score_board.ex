defmodule ScrawlyWeb.Components.ScoreBoard do
  use Hologram.Component

  alias ScrawlyWeb.Components.Avatar

  prop :players, :list, required: true
  # The current drawer (a pencil beside their name) and the players who have
  # guessed the word this round (a tick). Everyone sees both.
  prop :drawer_id, :string, default: nil
  prop :guessed_ids, :list, default: []

  def template do
    ~HOLO"""
    <div class="scoreboard">
      {%for {p, i} <- Enum.with_index(sorted_players(@players))}
        <div class={"item" <> if(p.id == @drawer_id, do: " drawing", else: "")}>
          <span class="rank">{String.pad_leading(Integer.to_string(i + 1), 2, "0")}</span>
          <span class="nm">
            <Avatar
              avatar_id={Map.get(p, :avatar_id) || "a-mushroom"}
              color={Map.get(p, :avatar_color) || "3"}
              size="xs" />
            <span class="sb-name">{p.username}</span>
            {%if p.id == @drawer_id}
              <span class="sb-mark" role="img" aria-label="drawing" title="drawing">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" width="13" height="13"><path d="M4 20l4-1 11-11-3-3L5 16l-1 4z" stroke-linejoin="round"/><path d="M14 6l3 3" /></svg>
              </span>
            {/if}
            {%if p.id in @guessed_ids}
              <span class="sb-mark guessed" role="img" aria-label="guessed it" title="guessed it">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" width="13" height="13"><path d="M5 12.5l4.5 4.5L19 7.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
              </span>
            {/if}
          </span>
          <span class="pts mono">{p.score || 0}</span>
        </div>
      {/for}
    </div>
    """
  end

  defp sorted_players(players) do
    Enum.sort_by(players, &(&1.score || 0), :desc)
  end

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
