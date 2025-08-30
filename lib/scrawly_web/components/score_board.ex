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
    <div class="bg-white rounded-lg shadow-md p-4">
      <!-- Game Status Header -->
      <div class="mb-4">
        <div class="flex items-center justify-between">
          <h3 class="text-lg font-semibold text-black">Game Status</h3>
          <div $show={@game_status == :playing} class="flex items-center gap-2">
            <div class="w-3 h-3 bg-green-400 rounded-full animate-pulse"></div>
            <span class="text-sm text-green-600 font-medium">Playing</span>
          </div>
          <div $show={@game_status == :lobby} class="flex items-center gap-2">
            <div class="w-3 h-3 bg-yellow-400 rounded-full"></div>
            <span class="text-sm text-yellow-600 font-medium">Lobby</span>
          </div>
          <div $show={@game_status == :ended} class="flex items-center gap-2">
            <div class="w-3 h-3 bg-red-400 rounded-full"></div>
            <span class="text-sm text-red-600 font-medium">Ended</span>
          </div>
        </div>

        <!-- Round Info -->
        <div $show={@game_status == :playing} class="mt-2 text-sm text-gray-600">
          <div class="flex items-center justify-between">
            <span>Round {@current_round} of {@total_rounds}</span>
            <span $show={@time_left > 0} class="font-mono">
              Time: {@time_left}s
            </span>
          </div>
        </div>

        <!-- Current Word (for drawer) -->
        <div $show={@current_word && @current_word != ""} class="mt-2 p-2 bg-blue-50 rounded-lg">
          <div class="text-sm text-blue-600 font-medium">
            Word to draw: <span class="font-bold">{@current_word}</span>
          </div>
        </div>
      </div>

      <!-- Scoreboard -->
      <div>
        <h4 class="text-md font-semibold text-black mb-3">Scoreboard</h4>

        <div $show={length(@players) == 0} class="text-center py-4 text-gray-500">
          <p>No players to show</p>
        </div>

                <div $show={length(@players) > 0} class="space-y-2">
          <div class="text-center py-4 text-gray-600">
            <p>{length(@players)} player(s) on scoreboard</p>
            <p class="text-sm mt-2">ScoreBoard component loaded successfully!</p>
          </div>
        </div>
      </div>

      <!-- Game Winner (when game ends) -->
      <div $show={@game_status == :ended && length(@players) > 0} class="mt-4 p-4 bg-yellow-50 rounded-lg border border-yellow-200">
        <div class="text-center">
          <div class="text-lg font-bold text-yellow-800 mb-2">🎉 Game Over! 🎉</div>
          <div class="text-md text-yellow-700">
            Winner: <span class="font-bold">{get_winner(@players).username || get_winner(@players).name || "Anonymous"}</span>
          </div>
          <div class="text-sm text-yellow-600">
            Final Score: {get_winner(@players).score || 0} points
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper function to sort players by score (descending)
  defp sorted_players(players) do
    Enum.sort_by(players, &(&1.score || 0), :desc)
  end

  # Helper function to get player rank
  defp get_player_rank(player, players) do
    sorted_players(players)
    |> Enum.with_index(1)
    |> Enum.find(fn {p, _rank} -> p.id == player.id end)
    |> case do
      {_player, rank} -> rank
      nil -> "?"
    end
  end

  # Helper function to get the winner (highest score)
  defp get_winner(players) do
    sorted_players(players)
    |> List.first() ||
      %{username: "No Winner", score: 0}
  end
end
