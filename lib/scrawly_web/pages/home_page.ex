defmodule ScrawlyWeb.Pages.HomePage do
  use Hologram.Page

  route "/"

  layout ScrawlyWeb.Layouts.AppLayout

  alias ScrawlyWeb.Components.RoomList

  def init(_params, component, _server) do
    component
    |> put_state(:rooms, [
      %{id: 1, name: "Room 1", player_count: 3, max_players: 8, is_private: false},
      %{id: 2, name: "Artists Only", player_count: 2, max_players: 6, is_private: true},
      %{id: 3, name: "Quick Draw", player_count: 5, max_players: 10, is_private: false}
    ])
    |> put_state(:show_create_room, false)
    |> put_state(:new_room_name, "")
  end

  def template do
    ~HOLO"""
    <div class="min-h-screen bg-gradient-to-br from-blue-50 to-indigo-100 p-4">
      <div class="max-w-4xl mx-auto">
        <div class="text-center mb-8">
          <h1 class="text-4xl font-bold text-black mb-2">Scrawly</h1>
          <p class="text-gray-600">Draw, guess, and have fun with friends!</p>
        </div>

        <!-- Debug Info -->
        <div class="text-center mb-4 text-xs text-gray-500">
          Show modal: {@show_create_room}
        </div>

        <div class="text-center mb-8">
          <button $click="show_create_room" class="bg-green-500 hover:bg-green-600 text-white font-semibold py-3 px-6 rounded-lg">
            Create New Room
          </button>
        </div>

        <div class={if(@show_create_room, do: "fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50", else: "hidden")}>
          <form class="bg-white rounded-lg p-6 w-full max-w-md" $submit="create_room">
            <h3 class="text-xl font-semibold mb-4">Create New Room</h3>
            <input
              type="text"
              placeholder="Room name..."
              class="w-full p-3 border border-gray-300 rounded-lg mb-4"
              value={@new_room_name}
              $input="update_room_name">
            <div class="flex gap-2">
              <button type="submit" class="flex-1 bg-green-500 hover:bg-green-600 text-white py-2 rounded-lg">
                Create
              </button>
              <button type="button" class="flex-1 bg-gray-300 hover:bg-gray-400 text-black py-2 rounded-lg" $click="hide_create_room">
                Cancel
              </button>
            </div>
          </form>
        </div>

        <RoomList
          rooms={@rooms}
          loading={false} />
      </div>
    </div>
    """
  end

  def action(:show_create_room, _params, component) do
    put_state(component, :show_create_room, true)
  end

  def action(:hide_create_room, _params, component) do
    component
    |> put_state(:show_create_room, false)
  end

  def action(:update_room_name, %{event: %{value: name}}, component) do
    put_state(component, :new_room_name, name)
  end

  def action(:create_room, params, component) do
    room_name = component.state.new_room_name

    if String.trim(room_name) != "" do
      component
      |> put_state(:show_create_room, false)
      |> put_page(ScrawlyWeb.Pages.GamePage, %{room_id: "new"})
    else
      component
    end
  end

  def action("join_room", %{"room_id" => room_id}, component) do
    put_page(component, ScrawlyWeb.Pages.GamePage, %{room_id: room_id})
  end
end
