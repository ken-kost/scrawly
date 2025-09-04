defmodule ScrawlyWeb.Pages.GamePage do
  use Hologram.Page

  route "/game/:room_id"

  layout ScrawlyWeb.Layouts.AppLayout

  param :room_id, :string

  alias ScrawlyWeb.Components.{PlayerList, ChatBox, ScoreBoard}

  def init(params, component, _server) do
    # Simulating room data for now
    component
    |> put_state(:room_id, params.room_id)
    |> put_state(:room_name, "Room #{params.room_id}")
    |> put_state(:players, [
      %{id: 1, username: "You", score: 0, is_connected: true},
      %{id: 2, username: "Alice", score: 15, is_connected: true},
      %{id: 3, username: "Bob", score: 8, is_connected: false}
    ])
    |> put_state(:current_drawer, %{id: 2, name: "Alice"})
    |> put_state(:current_word, "_ _ _   _ _ _ _")
    |> put_state(:time_left, 45)
    |> put_state(:round, 2)
    |> put_state(:total_rounds, 3)
    |> put_state(:chat_messages, [])
    |> put_state(:new_message, "")
    |> put_state(:is_drawer, false)
  end

  def action("send_message", _params, component) do
    message = component.state.new_message

    if String.trim(message) != "" do
      new_chat_message = %{
        id: :rand.uniform(10000),
        player_name: "You",
        message: message,
        timestamp: DateTime.utc_now(),
        is_guess: true
      }

      updated_messages = [new_chat_message | component.state.chat_messages] |> Enum.take(50)

      component
      |> put_state(:chat_messages, updated_messages)
      |> put_state(:new_message, "")
    else
      component
    end
  end

  def action("update_message", %{"value" => message}, component) do
    put_state(component, :new_message, message)
  end

  def action(:leave_room, _params, component) do
    put_page(component, ScrawlyWeb.Pages.HomePage)
  end

  def template do
    ~HOLO"""
    <div class="min-h-screen bg-gray-100 flex flex-col">
      <div class="bg-white shadow-sm border-b p-4">
        <div class="max-w-7xl mx-auto flex items-center justify-between">
          <div class="flex items-center gap-4">
            <button class="text-black hover:text-gray-700" $click="leave_room">← Back</button>
            <h1 class="text-xl font-semibold text-black">{@room_name}</h1>
            <span class="text-sm text-gray-500">Round {@round}/{@total_rounds}</span>
          </div>
          <div class="text-lg font-semibold text-green-600">{@time_left}s</div>
        </div>
      </div>

      <div class="flex-1 max-w-7xl mx-auto w-full p-4 grid grid-cols-1 lg:grid-cols-4 gap-4">
        <!-- Left Sidebar: Players & Score -->
        <div class="space-y-4">
          <PlayerList
            players={@players}
            current_drawer={@current_drawer}
            current_user_id="current_user" />

          <ScoreBoard
            players={@players}
            current_round={@round}
            total_rounds={@total_rounds}
            current_word={@current_word}
            time_left={@time_left}
            game_status={:playing} />
        </div>

        <!-- Center: Drawing Canvas -->
        <div class="lg:col-span-2 bg-white rounded-lg shadow-sm p-4">
          <div class="mb-4 flex items-center justify-between">
            <div class="text-lg font-mono tracking-wider">
              <span $show={@is_drawer}>{@current_word}</span>
              <span $show={!@is_drawer}>_ _ _ _ _</span>
            </div>
            <div class="text-sm text-gray-600">
              <span $show={@is_drawer}>Your turn to draw!</span>
              <span $show={!@is_drawer}>Guess the word!</span>
            </div>
          </div>
          <div class="border border-gray-300 bg-gray-50 h-96 rounded flex items-center justify-center">
            <p class="text-gray-500">Canvas placeholder - Drawing system coming soon!</p>
          </div>
        </div>

        <!-- Right Sidebar: Chat -->
        <div>
          <ChatBox
            messages={@chat_messages}
            current_message={@new_message}
            current_user_id="current_user"
            disabled={false} />
        </div>
      </div>
    </div>
    """
  end
end
