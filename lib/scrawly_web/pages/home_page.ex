defmodule ScrawlyWeb.Pages.HomePage do
  use Hologram.Page

  route "/"

  layout ScrawlyWeb.Layouts.AppLayout

  alias ScrawlyWeb.Components.RoomList

  def init(_params, component, _server) do
    # Always initialize the component with default state first to prevent template errors
    # component =
    component
    |> put_state(:rooms, Scrawly.Games.get_rooms!())
    |> put_state(:show_create_room, false)
    |> put_state(:new_room_name, "")
    |> put_state(:show_join_room, false)
    |> put_state(:join_room_email, "")
    |> put_state(:join_room_id, nil)
    |> put_state(:authenticated, false)

    # case HologramAuth.require_authentication(component, server) do
    #   {:ok, component, user} ->
    #     IO.puts("User authenticated: #{inspect(user)}")
    #     # User is authenticated, update component with user state
    #     component
    #     |> HologramAuth.put_user_state(user)
    #     |> put_state(:new_room_name, "Test Room")

    #   {:redirect, redirect_component} ->
    #     IO.puts("User NOT authenticated, redirecting...")
    #     # User is not authenticated, redirect to sign-in
    #     redirect_component
    # end
  end

  def template do
    ~HOLO"""
    <div class="min-h-screen bg-gradient-to-br from-blue-50 to-indigo-100 p-4">
      <div class="max-w-4xl mx-auto">
        <div class="text-center mb-8">
          <h1 class="text-4xl font-bold text-black mb-2">Scrawly</h1>
          <p class="text-gray-600">Draw, guess, and have fun with friends!</p>
        </div>


        <div class="text-center mb-8">
          <button $click={:show_create_room} class="bg-green-500 hover:bg-green-600 text-white font-semibold py-3 px-6 rounded-lg">
            Create New Room
          </button>
        </div>

        <!-- Create Room Modal -->
        <div class={if(@show_create_room, do: "fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50", else: "hidden")}>
          <form class="bg-white rounded-lg p-6 w-full max-w-md" $submit="create_room">
            <h3 class="text-xl font-semibold mb-4">Create New Room</h3>
            <input
              type="text"
              placeholder="Room name..."
              class="w-full p-3 border border-gray-300 rounded-lg mb-4"
              value={@new_room_name}
              $input={:update_room_name}>
            <div class="flex gap-2">
              <button type="submit" class="flex-1 bg-green-500 hover:bg-green-600 text-white py-2 rounded-lg">
                Create
              </button>
              <button type="button" class="flex-1 bg-gray-300 hover:bg-gray-400 text-black py-2 rounded-lg" $click={:hide_create_room}>
                Cancel
              </button>
            </div>
          </form>
        </div>

        <!-- Join Room Modal -->
        <div class={if(@show_join_room, do: "fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50", else: "hidden")}>
          <form class="bg-white rounded-lg p-6 w-full max-w-md" $submit="join_room_with_email">
            <h3 class="text-xl font-semibold mb-4">Join Room</h3>
            <p class="text-gray-600 mb-4 text-sm">Enter your email to join the room</p>
            <input
              type="email"
              placeholder="Your email..."
              class="w-full p-3 border border-gray-300 rounded-lg mb-4"
              value={@join_room_email}
              $input={:update_join_room_email}>
            <div class="flex gap-2">
              <button type="submit" class="flex-1 bg-blue-500 hover:bg-blue-600 text-white py-2 rounded-lg">
                Join
              </button>
              <button type="button" class="flex-1 bg-gray-300 hover:bg-gray-400 text-black py-2 rounded-lg" $click={:hide_join_room}>
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

  def action(:show_join_room, %{room_id: room_id}, component) do
    component
    |> put_state(:show_join_room, true)
    |> put_state(:join_room_id, room_id)
  end

  def action(:hide_join_room, _params, component) do
    component
    |> put_state(:show_join_room, false)
    |> put_state(:join_room_email, "")
    |> put_state(:join_room_id, nil)
  end

  def action(:update_room_name, %{event: %{value: name}}, component) do
    put_state(component, :new_room_name, name)
  end

  def action(:update_join_room_email, %{event: %{value: email}}, component) do
    put_state(component, :join_room_email, email)
  end

  def action(:create_room, _params, component) do
    room_name = component.state.new_room_name

    component |> put_command(:create_room, name: room_name, max_players: 10)
  end

  def action(:join_room_with_email, _params, component) do
    email = component.state.join_room_email
    room_id = component.state.join_room_id
    component |> put_command(:create_user, email: email, room_id: room_id)
  end

  def action(:home, _params, component) do
    put_page(component, ScrawlyWeb.Pages.HomePage)
  end

  def action(:join_room, %{room_id: room_id}, component) do
    # Show the join room modal instead of direct navigation
    component
    |> put_state(:show_join_room, true)
    |> put_state(:join_room_id, room_id)
  end

  def action(:join_room_with_user, %{room_id: room_id}, component) do
    put_page(component, ScrawlyWeb.Pages.GamePage, room_id: room_id)
  end

  def action(:watch_room, %{room_id: room_id}, component) do
    IO.inspect("Watching room: #{room_id}")
    put_page(component, ScrawlyWeb.Pages.GamePage, room_id: room_id)
  end

  def command(:create_room, params, component) do
    case Scrawly.Games.create_room(params) do
      {:ok, _room} -> put_action(component, :home)
      {:error, _} -> component
    end
  end

  def command(:create_user, %{email: email, room_id: room_id}, component) do
    with {:ok, user} <- Scrawly.Accounts.create_user(email),
         {:ok, _player} <- Scrawly.Accounts.join_room(user, room_id) do
      component
      |> put_session(:user_id, user.id)
      |> put_action(:join_room_with_user, room_id: room_id)
    else
      {:error, _reason} ->
        # TODO: Show error message to user
        component
    end
  end
end
