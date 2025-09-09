defmodule ScrawlyWeb.Pages.GamePage do
  use Hologram.Page

  @watcher %{username: "Watcher", id: "Watcher"}

  route "/game/:room_id"

  layout ScrawlyWeb.Layouts.AppLayout

  param :room_id, :string

  alias ScrawlyWeb.Components.{PlayerList, ChatBox, ScoreBoard, DrawingCanvas}
  alias Scrawly.Games

  def init(%{room_id: room_id}, component, server) do
    case Games.get_room_by_id(room_id) do
      {:ok, room} ->
        user_id = get_session(server, :user_id)

        component
        |> put_state(:watching?, user_id == "Watcher")
        |> put_state(:room_id, room_id)
        |> put_state(:room_code, room.code)
        |> put_state(:room_name, "Room #{room.name}")
        |> put_state(:room_status, room.status)
        |> put_state(:game_id, "")
        |> put_state(:players, room.players)
        |> put_state(:current_drawer, @watcher)
        |> put_state(:current_word, "")
        |> put_state(:current_word_display, "")
        |> put_state(:time_left, 0)
        |> put_state(:round, 1)
        |> put_state(:total_rounds, 5)
        |> put_state(:chat_messages, [])
        |> put_state(:new_message, "")
        |> put_state(:is_drawer, false)
        |> put_state(:game_started, room.status == :playing)
        |> put_state(:can_start_game, false)
        |> put_state(:current_user_username, "")
        |> put_state(:current_user_id, user_id)
        |> put_state(:current_user, @watcher)
        |> load_user_data(user_id)
        |> put_state(:can_start_game, length(room.players) >= 2)
        |> check_game_status()

      {:error, _} ->
        # Room not found, redirect to home
        put_page(component, ScrawlyWeb.Pages.HomePage)
    end
  end

  defp load_user_data(component, "Watcher") do
    component
    |> put_state(:current_user, @watcher)
    |> put_state(:current_user_username, "Watcher")
  end

  defp load_user_data(component, user_id) do
    case Ash.get(Scrawly.Accounts.User, user_id) do
      {:ok, user} ->
        component
        |> put_state(:current_user, user)
        |> put_state(:current_user_username, user.username)

      {:error, _} ->
        # User not found, keep defaults
        component
    end
  end

  defp check_game_status(component) do
    case component.state.room_status do
      :playing ->
        # Try to get current game
        # TODO: Get actual game from room
        component
        |> put_state(:game_started, true)
        |> put_state(:round, 1)
        |> put_state(:current_word_display, "_ _ _ _ _")

      _ ->
        component
        |> put_state(:game_started, false)
    end
  end

  def action(:send_message, _params, component) do
    message = component.state.new_message

    if String.trim(message) != "" do
      player_name = Map.get(component.state, :current_user_username, "You")

      new_chat_message = %{
        id: :rand.uniform(10000),
        player_name: player_name,
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

  def action(:update_message, %{event: %{value: message}}, component) do
    put_state(component, :new_message, message)
  end

  def action(:leave_room, _params, component) do
    put_page(component, ScrawlyWeb.Pages.HomePage)
  end

  def action(:start_game, params, component) do
    component
    |> put_state(:game_started, true)
    |> put_state(:game_id, params.game_id)
    |> put_state(:round, params.round)
    |> put_state(:current_drawer, %{
      id: params.first_drawer_id,
      name: get_player_name(params.players, params.first_drawer_id)
    })
    |> put_state(:current_word, params.current_word)
    |> put_state(:current_word_display, generate_word_display(params.current_word))
    |> put_state(:is_drawer, params.first_drawer_id == Map.get(component.state, :current_user_id))
    |> put_state(:time_left, 80)
  end

  def action(:next_round, params, component) do
    component
    |> put_state(:round, params.round)
    |> put_state(:current_drawer, %{
      id: params.current_drawer_id,
      name: get_player_name(params.players, params.current_drawer_id)
    })
    |> put_state(:current_word, params.current_word)
    |> put_state(:current_word_display, generate_word_display(params.current_word))
    |> put_state(
      :is_drawer,
      params.current_drawer_id == Map.get(component.state, :current_user_id)
    )
    |> put_state(:time_left, 80)
  end

  def action(:end_game, _params, component) do
    component
    |> put_state(:game_started, false)
    |> put_state(:game_id, nil)
    |> put_state(:current_drawer, nil)
    |> put_state(:current_word, nil)
    |> put_state(:current_word_display, "")
    |> put_state(:time_left, 0)
    |> put_state(:is_drawer, false)
  end

  def action(:update_timer, %{time_left: time_left}, component) do
    put_state(component, :time_left, time_left)
  end

  def action(:round_timeout, _params, component) do
    # Handle when timer runs out - just set time to 0, next round will be triggered by UI
    put_state(component, :time_left, 0)
  end

  def command(:start_game, %{room_id: room_id, players: players}, server) do
    first_drawer_id = List.first(players).id

    with {:ok, _room} <- Games.start_game(room_id),
         {:ok, game} <- Games.create_game(room_id, 5),
         {:ok, updated_game} <- Games.start_round(game.id, first_drawer_id),
         :ok <- Games.start_round_timer(game.id) do
      put_action(server, :start_game,
        game_id: game.id,
        round: updated_game.current_round,
        first_drawer_id: first_drawer_id,
        current_word: updated_game.current_word,
        players: players
      )
    else
      {:error, _reason} -> server
    end
  end

  def command(:next_round, %{game_id: game_id, players: players}, server) do
    if game_id do
      player_queue = Enum.map(players, & &1.id)

      with {:ok, _game} <- Games.complete_round(game_id),
           {:ok, _updated_game} <- Games.next_round(game_id),
           {:ok, game_with_drawer} <- Games.select_next_drawer(game_id, player_queue),
           {:ok, final_game} <- Games.start_round(game_id, game_with_drawer.current_drawer_id),
           :ok <- Games.start_round_timer(game_id) do
        put_action(server, :next_round,
          round: final_game.current_round,
          current_drawer_id: final_game.current_drawer_id,
          current_word: final_game.current_word,
          players: players
        )
      else
        {:error, _reason} -> server
      end
    else
      server
    end
  end

  def command(:end_game, %{game_id: game_id, room_id: room_id}, server) do
    if game_id do
      # Stop timer
      Games.stop_round_timer(game_id)

      # End the game
      Games.end_current_game(game_id)
      Games.end_game(room_id)

      put_action(server, :end_game, [])
    else
      server
    end
  end

  defp get_player_name(players, player_id) do
    case Enum.find(players, &(&1.id == player_id)) do
      nil -> "Unknown"
      player -> player.username
    end
  end

  defp generate_word_display(word) when is_binary(word) do
    word
    |> String.split("")
    |> Enum.map(fn
      " " -> "  "
      "" -> ""
      _char -> "_ "
    end)
    |> Enum.join("")
    |> String.trim()
  end

  defp generate_word_display(_), do: ""

  def template do
    ~HOLO"""
    <div class="min-h-screen bg-gray-100 flex flex-col">
      <div class="bg-white shadow-sm border-b p-4">
        <div class="max-w-7xl mx-auto flex items-center justify-between">
          <div class="flex items-center gap-4">
            <button class="text-black hover:text-gray-700" $click={:leave_room}>← Back</button>
            <h1 class="text-xl font-semibold text-black">{@room_name}</h1>
            <span class="text-sm text-gray-500" $show={@game_started}>Round {@round}/{@total_rounds}</span>
            <span class="text-sm text-yellow-600" $show={!@game_started}>Waiting to start...</span>
          </div>
          <div class="flex items-center gap-4">
            <div class="text-lg font-semibold text-gray-400">
               {@time_left}s
            </div>
            <!-- Game Control Buttons -->
            <button
              class="px-4 py-2 bg-green-600 text-white rounded hover:bg-green-700 disabled:opacity-50"
              $show={!@game_started && @can_start_game}
              $click={command: :start_game, params: %{room_id: @room_id, players: @players}}>
              Start Game
            </button>
            <button
              class="px-3 py-1 bg-blue-600 text-white rounded text-sm hover:bg-blue-700"
              $show={@game_started && @time_left == 0}
              $click={command: :next_round, params: %{game_id: @game_id, players: @players}}>
              Next Round
            </button>
            <button
              class="px-3 py-1 bg-red-600 text-white rounded text-sm hover:bg-red-700"
              $show={@game_started}
              $click={command: :end_game, params: %{game_id: @game_id, room_id: @room_id}}>
              End Game
            </button>
          </div>
        </div>
      </div>

      <!-- Game Not Started State -->
      <div class="flex-1 flex items-center justify-center" $show={!@game_started}>
        <div class="text-center">
          <div class="text-6xl mb-4">🎨</div>
          <h2 class="text-2xl font-bold text-gray-800 mb-2">Ready to {if(@watching?, do: "Watch", else: "Play" <> " " <> @current_user_username)}?</h2>
          <p class="text-gray-600 mb-6">
            {%for player <- @players}
              <span>{player.username}</span>
            {/for}
           {%if !@can_start_game}
              <span> • Need at least 2 players to start</span>
            {/if}
          </p>
          <button
            class="px-6 py-3 bg-green-600 text-white rounded-lg text-lg hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed"
            disabled={!@can_start_game and not @watching?}
            $click={command: :start_game, params: %{room_id: @room_id, players: @players}}>
            {if((@can_start_game), do: "Start Game", else: "Waiting for players...")}
          </button>
        </div>
      </div>

      <!-- Active Game State -->
      <div class="flex-1 max-w-7xl mx-auto w-full p-4 grid grid-cols-1 lg:grid-cols-4 gap-4" $show={@game_started}>
        <!-- Left Sidebar: Players & Score -->
        <div class="space-y-4">
          <PlayerList
            players={@players}
            current_drawer={@current_drawer}
            current_user_id={@current_user_id} />

          <ScoreBoard
            players={@players}
            current_round={@round}
            total_rounds={@total_rounds}
            current_word={@current_word_display}
            time_left={@time_left}
            game_status={:playing} />
        </div>

        <!-- Center: Drawing Canvas -->
        <div class="lg:col-span-2 bg-white rounded-lg shadow-sm p-4">
          <div class="mb-4 flex items-center justify-between">
            <div class="text-lg font-mono tracking-wider">
              <span $show={@is_drawer and @current_word} class="text-blue-600 font-bold">{@current_word}</span>
              <span $show={!@is_drawer and @current_word_display} class="text-gray-800">{@current_word_display}</span>
              <span $show={!@current_word and !@current_word_display} class="text-gray-400">Waiting for word...</span>
            </div>
            <div class="text-sm text-gray-600">
              <span $show={@is_drawer} class="text-green-600 font-semibold">Your turn to draw!</span>
              <span $show={!@is_drawer} class="text-blue-600 font-semibold">Guess the word!</span>
            </div>
          </div>

          <!-- Current Drawer Info -->
          <div class="mb-4 p-3 bg-gray-50 rounded-lg" $show={@current_drawer}>
            <div class="flex items-center gap-2">
              <div class="w-3 h-3 bg-green-500 rounded-full animate-pulse"></div>
              <span class="font-medium">{@current_drawer && @current_drawer.username}</span>
              <span class="text-sm text-gray-500">is drawing</span>
            </div>
          </div>

          <DrawingCanvas
            cid="drawing_canvas"
            room_id={@room_id}
            is_drawer={@is_drawer}
            disabled={!@game_started or @time_left == 0}
            />
        </div>

        <!-- Right Sidebar: Chat -->
        <div>
          <ChatBox
            messages={@chat_messages}
            current_message={@new_message}
            current_user_id={@current_user_id}
            disabled={!@game_started}
          />
        </div>
      </div>
    </div>
    """
  end
end
