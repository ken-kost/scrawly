defmodule ScrawlyWeb.Components.PlayerList do
  use Hologram.Component

  prop :players, :list, default: []
  prop :current_drawer, :map, default: nil
  prop :current_user_id, :string, default: nil

  def template do
    ~HOLO"""
    <div class="bg-white rounded-lg shadow-md p-4">
      <h3 class="text-lg font-semibold text-black mb-4">Players ({length(@players)})</h3>

      <div $show={length(@players) == 0} class="text-center py-4 text-gray-500">
        <p>No players yet</p>
      </div>

            <div $show={length(@players) > 0} class="space-y-2">
        <div class="text-center py-4 text-gray-600">
          <p>{length(@players)} player(s) in game</p>
          <p class="text-sm mt-2">PlayerList component loaded successfully!</p>
        </div>
      </div>
    </div>
    """
  end
end
