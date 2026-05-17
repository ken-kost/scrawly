defmodule ScrawlyWeb.Components.ScoreBoard do
  use Hologram.Component

  prop :players, :list, default: []
  prop :current_round, :integer, default: 1
  prop :total_rounds, :integer, default: 3
  prop :current_word, :string, default: nil
  prop :time_left, :integer, default: 0
  prop :game_status, :atom, default: :lobby

  def template do
    ~HOLO"""
    <div class="scoreboard">
      {%for {p, i} <- Enum.with_index(sorted_players(@players))}
        <div class="item">
          <span class="rank">{String.pad_leading(Integer.to_string(i + 1), 2, "0")}</span>
          <span class="nm">
            <span style={"width: 8px; height: 8px; border-radius: 999px; background: " <> Scrawly.Games.PlayerColor.for(p.id) <> "; display: inline-block;"}></span>
            {p.username}
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
end
