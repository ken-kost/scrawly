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
          <div class="bg-gray-50 rounded-lg p-4 border hover:bg-gray-100 transition-colors">
            <div class="flex justify-between items-center">
              <div class="flex-1">
                <h3 class="font-semibold text-lg text-black">Room 1</h3>
                <div class="text-sm text-gray-600 mt-1">
                  <span>3/8 players</span>
                </div>
              </div>
              <div class="flex gap-2">
                <button 
                  class="bg-blue-500 hover:bg-blue-600 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors" 
                  $click={"join_room", %{room_id: "1"}}>
                  Join
                </button>
                <button 
                  class="bg-gray-300 hover:bg-gray-400 text-black px-4 py-2 rounded-lg text-sm font-medium transition-colors" 
                  $click={"watch_room", %{room_id: "1"}}>
                  Watch
                </button>
              </div>
            </div>
          </div>

          <!-- Room 2 -->
          <div class="bg-gray-50 rounded-lg p-4 border hover:bg-gray-100 transition-colors">
            <div class="flex justify-between items-center">
              <div class="flex-1">
                <h3 class="font-semibold text-lg text-black">Artists Only</h3>
                <div class="text-sm text-gray-600 mt-1">
                  <span>2/6 players</span>
                  <span class="ml-2 bg-yellow-200 text-yellow-800 px-2 py-1 rounded text-xs">
                    Private
                  </span>
                </div>
              </div>
              <div class="flex gap-2">
                <button 
                  class="bg-blue-500 hover:bg-blue-600 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors" 
                  $click={"join_room", %{room_id: "2"}}>
                  Join
                </button>
                <button 
                  class="bg-gray-300 hover:bg-gray-400 text-black px-4 py-2 rounded-lg text-sm font-medium transition-colors" 
                  $click={"watch_room", %{room_id: "2"}}>
                  Watch
                </button>
              </div>
            </div>
          </div>

          <!-- Room 3 -->
          <div class="bg-gray-50 rounded-lg p-4 border hover:bg-gray-100 transition-colors">
            <div class="flex justify-between items-center">
              <div class="flex-1">
                <h3 class="font-semibold text-lg text-black">Quick Draw</h3>
                <div class="text-sm text-gray-600 mt-1">
                  <span>5/10 players</span>
                </div>
              </div>
              <div class="flex gap-2">
                <button 
                  class="bg-blue-500 hover:bg-blue-600 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors" 
                  $click={"join_room", %{room_id: "3"}}>
                  Join
                </button>
                <button 
                  class="bg-gray-300 hover:bg-gray-400 text-black px-4 py-2 rounded-lg text-sm font-medium transition-colors" 
                  $click={"watch_room", %{room_id: "3"}}>
                  Watch
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def action("join_room", %{"room_id" => room_id}, component) do
    # Navigate directly to the game page
    put_page(component, ScrawlyWeb.Pages.GamePage, %{room_id: room_id})
  end

  def action("watch_room", %{"room_id" => room_id}, component) do
    # Navigate directly to the game page (same as join for now)
    put_page(component, ScrawlyWeb.Pages.GamePage, %{room_id: room_id})
  end
end
