defmodule ScrawlyWeb.GameChannel do
  use ScrawlyWeb, :channel

  alias Scrawly.Games
  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Presence

  @rate_limit_max_messages 5
  @rate_limit_window_seconds 3

  defp ensure_rate_limit_table do
    case :ets.info(:chat_rate_limit) do
      :undefined ->
        :ets.new(:chat_rate_limit, [:set, :named_table, :public])
        :ok

      _ ->
        :ok
    end
  end

  defp check_rate_limit(user_id) do
    ensure_rate_limit_table()
    now = System.system_time(:second)
    key = "chat:#{user_id}"

    case :ets.lookup(:chat_rate_limit, key) do
      [{^key, count, first_message_time}] ->
        if now - first_message_time < @rate_limit_window_seconds do
          if count >= @rate_limit_max_messages do
            {:error, :rate_limit_exceeded}
          else
            :ets.update_counter(:chat_rate_limit, key, {2, 1})
            {:ok, :continue}
          end
        else
          :ets.insert(:chat_rate_limit, {key, 1, now})
          {:ok, :continue}
        end

      [] ->
        :ets.insert(:chat_rate_limit, {key, 1, now})
        {:ok, :continue}
    end
  end

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

      # Subscribe to game events (timer) and room state changes
      Phoenix.PubSub.subscribe(Scrawly.PubSub, "game:#{room.id}")
      Phoenix.PubSub.subscribe(Scrawly.PubSub, "room:#{room.id}")

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

  # Drawing events — stroke objects with path, color, and width
  @impl true
  def handle_in("drawing_segment", %{"segment" => ""}, socket) do
    {:reply, {:error, %{reason: "empty_segment"}}, socket}
  end

  @impl true
  def handle_in("drawing_stroke", payload, socket) do
    segment = payload["segment"] || payload["path"] || ""
    color = payload["color"] || "#000000"
    width = payload["width"] || 2

    if segment == "" do
      {:reply, {:error, %{reason: "empty_segment"}}, socket}
    else
      room_id = socket.assigns.room_id
      stroke = %{path: segment, color: color, width: width}
      RoomServer.append_drawing(room_id, stroke)

      broadcast_from(socket, "drawing_stroke", %{
        "path" => segment,
        "color" => color,
        "width" => width
      })

      {:reply, {:ok, %{status: "stroke_received"}}, socket}
    end
  end

  @impl true
  def handle_in("drawing_segment", %{"segment" => segment}, socket)
      when is_binary(segment) and byte_size(segment) > 0 do
    room_id = socket.assigns.room_id
    stroke = %{path: segment, color: "#000000", width: 2}
    RoomServer.append_drawing(room_id, stroke)

    broadcast_from(socket, "drawing_stroke", %{
      "path" => segment,
      "color" => "#000000",
      "width" => 2
    })

    {:reply, {:ok, %{status: "segment_received"}}, socket}
  end

  @impl true
  def handle_in("drawing_clear", _payload, socket) do
    room_id = socket.assigns.room_id
    RoomServer.clear_drawing(room_id)
    broadcast_from(socket, "drawing_clear", %{})
    {:reply, {:ok, %{status: "drawing_cleared"}}, socket}
  end

  @impl true
  def handle_in("drawing_undo", _payload, socket) do
    room_id = socket.assigns.room_id

    case RoomServer.undo_drawing(room_id) do
      {:ok, strokes} ->
        broadcast_from(socket, "drawing_undo", %{"strokes" => strokes})
        {:reply, {:ok, %{status: "undo_done", strokes: strokes}}, socket}

      _ ->
        {:reply, {:ok, %{status: "undo_noop"}}, socket}
    end
  end

  @impl true
  def handle_in("get_drawing_path", _payload, socket) do
    case RoomServer.get_state(socket.assigns.room_id) do
      {:ok, state} ->
        {:reply, {:ok, %{strokes: state.drawing_strokes || []}}, socket}

      {:error, _} ->
        {:reply, {:ok, %{strokes: []}}, socket}
    end
  end

  @chat_max_messages 3
  @chat_window_ms 5_000

  # Chat events — rate limited to @chat_max_messages per @chat_window_ms on the server
  @impl true
  def handle_in("chat_message", %{"message" => message}, socket) when byte_size(message) > 0 do
    now = System.monotonic_time(:millisecond)
    timestamps = Map.get(socket.assigns, :chat_timestamps, [])
    recent = Enum.filter(timestamps, &(now - &1 < @chat_window_ms))

    if length(recent) >= @chat_max_messages do
      {:reply, {:error, %{reason: "rate_limited"}}, socket}
    else
      user_id = socket.assigns.user_id
      socket = assign(socket, :chat_timestamps, [now | recent])

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
    user_id = socket.assigns.user_id
    room_id = socket.assigns.room_id

    with {:ok, user} <- Ash.get(Scrawly.Accounts.User, user_id) do
      rs_state =
        case RoomServer.get_state(room_id) do
          {:ok, rs} -> rs
          _ -> %{current_drawer_id: nil, players: []}
        end

      is_drawer = rs_state.current_drawer_id == user_id
      player = Enum.find(rs_state.players, &(&1.id == user_id))
      score = if player, do: player.score || 0, else: 0

      {:ok, _} =
        Presence.track(socket, to_string(user_id), %{
          username: user.username || "Anonymous",
          player_state: user.player_state || :connected,
          score: score,
          is_drawer: is_drawer,
          joined_at: System.system_time(:second)
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

  # Handle room state change broadcasts — notify client to fetch fresh state
  @impl true
  def handle_info(:room_state_changed, socket) do
    push(socket, "room_state_changed", %{})
    {:noreply, socket}
  end
end
