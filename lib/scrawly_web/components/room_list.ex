defmodule ScrawlyWeb.Components.RoomList do
  use Hologram.Component

  prop :rooms, :list, default: []
  prop :loading, :boolean, default: false

  def template do
    ~HOLO"""
    <div class="bg-white rounded-lg shadow-md">
      <div class="p-4 border-b border-gray-200">
        <h2 class="text-xl font-semibold text-black">Available Rooms</h2>
      </div>

      <div class="p-4">
        <!-- Loading State -->
        <div class={if(@loading, do: "text-center py-8", else: "hidden")}>
          <div class="inline-block animate-spin rounded-full h-8 w-8 border-b-2 border-blue-500"></div>
          <p class="mt-2 text-gray-600">Loading rooms...</p>
        </div>

        <!-- No Rooms State -->
        <div class={if(!@loading && length(@rooms) == 0, do: "text-center py-8 text-gray-500", else: "hidden")}>
          <p>No rooms available. Create one to get started!</p>
        </div>

        <!-- Rooms List -->
        <div class={if(!@loading && length(@rooms) > 0, do: "grid gap-4", else: "hidden")}>
          <!-- Room 1 -->
        {%for room <- @rooms}
          <div class="bg-gray-50 rounded-lg p-4 border hover:bg-gray-100 transition-colors">
            <div class="flex justify-between items-center">
              <div class="flex-1">
                <h3 class="font-semibold text-lg text-black">{room.name}</h3>
                <div class="text-sm text-gray-600 mt-1">
                  <span>{length(room.players)}/{room.max_players} players</span>
                </div>
              </div>
              <div class="flex gap-2">
                <button
                  class="bg-blue-500 hover:bg-blue-600 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors"
                  $click={:join_room, room_id: room.id}>
                  Join
                </button>
                <button
                  class="bg-gray-300 hover:bg-gray-400 text-black px-4 py-2 rounded-lg text-sm font-medium transition-colors"
                  $click={:watch_room, room_id: room.id}>
                  Watch
                </button>
              </div>
            </div>
          </div>
        {/for}
        </div>
      </div>
    </div>
    """
  end
end
