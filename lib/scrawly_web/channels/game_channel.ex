defmodule ScrawlyWeb.GameChannel do
  use ScrawlyWeb, :channel

  alias Scrawly.Games
  alias ScrawlyWeb.Presence

  @impl true
  def join("game:" <> room_code, _payload, socket) do
    with {:ok, room} <- Games.get_room_by_code(room_code),
         user_id when not is_nil(user_id) <- socket.assigns[:user_id],
         {:ok, _user} <- Ash.get(Scrawly.Accounts.User, user_id) do
      socket =
        socket
        |> assign(:room_code, room_code)
        |> assign(:room_id, room.id)
        |> assign(:user_id, user_id)

      # Subscribe to game events for this room
      # Note: We'll subscribe based on game_id when a game starts
      Phoenix.PubSub.subscribe(Scrawly.PubSub, "game:#{room.id}")

      # Track the user's presence in the room
      send(self(), :after_join)

      {:ok, socket}
    else
      {:error, _} ->
        {:error, %{reason: "invalid_room"}}

      nil ->
        {:error, %{reason: "unauthorized"}}

      _ ->
        {:error, %{reason: "join_failed"}}
    end
  end

  # Drawing events
  @impl true
  def handle_in("drawing_start", %{"x" => x, "y" => y}, socket) do
    broadcast_from(socket, "drawing_start", %{
      "x" => x,
      "y" => y,
      "player_id" => socket.assigns.user_id
    })

    {:reply, {:ok, %{status: "drawing_started"}}, socket}
  end

  @impl true
  def handle_in("drawing_move", %{"x" => x, "y" => y}, socket) do
    broadcast_from(socket, "drawing_move", %{
      "x" => x,
      "y" => y,
      "player_id" => socket.assigns.user_id
    })

    {:reply, {:ok, %{status: "drawing_moved"}}, socket}
  end

  @impl true
  def handle_in("drawing_stop", _payload, socket) do
    broadcast_from(socket, "drawing_stop", %{
      "player_id" => socket.assigns.user_id
    })

    {:reply, {:ok, %{status: "drawing_stopped"}}, socket}
  end

  # Chat events
  @impl true
  def handle_in("chat_message", %{"message" => message}, socket) when byte_size(message) > 0 do
    user_id = socket.assigns.user_id

    case Ash.get(Scrawly.Accounts.User, user_id) do
      {:ok, user} ->
        broadcast(socket, "chat_message", %{
          "message" => message,
          "username" => user.username || "Anonymous",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:reply, {:ok, %{status: "message_sent"}}, socket}

      _ ->
        {:reply, {:error, %{reason: "user_not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("chat_message", %{"message" => ""}, socket) do
    {:reply, {:error, %{reason: "empty_message"}}, socket}
  end

  @impl true
  def handle_in("chat_message", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_message"}}, socket}
  end

  # Game state events
  @impl true
  def handle_in("start_game", _payload, socket) do
    room_id = socket.assigns.room_id

    case Games.start_game(room_id) do
      {:ok, room} ->
        broadcast(socket, "game_started", %{
          "room_status" => room.status,
          "current_round" => room.current_round
        })

        {:reply, {:ok, %{status: "game_started"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("end_game", _payload, socket) do
    room_id = socket.assigns.room_id

    case Games.end_game(room_id) do
      {:ok, room} ->
        broadcast(socket, "game_ended", %{
          "room_status" => room.status,
          # TODO: Add final scores when scoring is implemented
          "final_scores" => %{}
        })

        {:reply, {:ok, %{status: "game_ended"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("round_start", %{"round_number" => round_number}, socket) do
    broadcast(socket, "round_started", %{
      "round_number" => round_number,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:reply, {:ok, %{status: "round_started"}}, socket}
  end

  @impl true
  def handle_in("round_end", %{"round_number" => round_number}, socket) do
    broadcast(socket, "round_ended", %{
      "round_number" => round_number,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:reply, {:ok, %{status: "round_ended"}}, socket}
  end

  @impl true
  def handle_in("turn_change", %{"drawer_id" => drawer_id}, socket) do
    broadcast(socket, "turn_changed", %{
      "drawer_id" => drawer_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:reply, {:ok, %{status: "turn_changed"}}, socket}
  end

  # Round timer events
  @impl true
  def handle_in("start_round_timer", %{"game_id" => game_id}, socket) do
    case Games.start_round_timer(game_id) do
      :ok ->
        {:reply, {:ok, %{status: "timer_started"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("stop_round_timer", %{"game_id" => game_id}, socket) do
    case Games.stop_round_timer(game_id) do
      :ok ->
        {:reply, {:ok, %{status: "timer_stopped"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("get_timer_status", %{"game_id" => game_id}, socket) do
    remaining_seconds = Games.get_round_time_remaining(game_id)

    {:reply, {:ok, %{remaining_seconds: remaining_seconds}}, socket}
  end

  # Handle presence tracking after join
  @impl true
  def handle_info(:after_join, socket) do
    with {:ok, user} <- Ash.get(Scrawly.Accounts.User, socket.assigns.user_id) do
      {:ok, _} =
        Presence.track(socket, to_string(socket.assigns.user_id), %{
          username: user.username || "Anonymous",
          player_state: user.player_state || :connected,
          joined_at: inspect(System.system_time(:second))
        })

      push(socket, "presence_state", Presence.list(socket))
    end

    {:noreply, socket}
  end

  # Handle timer PubSub messages
  @impl true
  def handle_info({:timer_started, %{game_id: game_id, duration_seconds: duration}}, socket) do
    push(socket, "timer_started", %{
      game_id: game_id,
      duration_seconds: duration,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:timer_update, %{game_id: game_id, remaining_seconds: remaining}}, socket) do
    push(socket, "timer_update", %{
      game_id: game_id,
      remaining_seconds: remaining,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:timer_stopped, %{game_id: game_id}}, socket) do
    push(socket, "timer_stopped", %{
      game_id: game_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:round_ended, %{game_id: game_id, reason: reason}}, socket) do
    push(socket, "round_ended_timer", %{
      game_id: game_id,
      reason: reason,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:noreply, socket}
  end
end
