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
        <div $show={@loading} class="text-center py-8">
          <div class="inline-block animate-spin rounded-full h-8 w-8 border-b-2 border-blue-500"></div>
          <p class="mt-2 text-gray-600">Loading rooms...</p>
        </div>

        <!-- No Rooms State -->
        <div $show={!@loading && length(@rooms) == 0} class="text-center py-8 text-gray-500">
          <p>No rooms available. Create one to get started!</p>
        </div>

                <!-- Rooms List -->
        <div $show={!@loading && length(@rooms) > 0} class="grid gap-4">
          <div class="text-center py-4 text-gray-600">
            <p>Found {length(@rooms)} room(s)</p>
            <p class="text-sm mt-2">Room list component loaded successfully!</p>
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
