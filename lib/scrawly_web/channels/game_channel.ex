defmodule ScrawlyWeb.GameChannel do
  use ScrawlyWeb, :channel

  alias Scrawly.Games
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

    case check_rate_limit(user_id) do
      {:error, :rate_limit_exceeded} ->
        {:reply, {:error, %{reason: "rate_limit_exceeded"}}, socket}

      {:ok, :continue} ->
        room_id = socket.assigns.room_id

        case Ash.get(Scrawly.Accounts.User, user_id) do
          {:ok, user} ->
            handle_chat_message(socket, user, room_id, message)

          _ ->
            {:reply, {:error, %{reason: "user_not_found"}}, socket}
        end
    end
  end

  defp handle_chat_message(socket, user, room_id, message) do
    user_id = user.id

    case Games.get_game_by_room(room_id) do
      {:ok, [game | _]} ->
        current_word = game.current_word
        drawer_id = game.current_drawer_id

        guess_result = check_guess(message, current_word, user_id, drawer_id, game.id)

        broadcast(socket, "chat_message", %{
          "message" => message,
          "username" => user.username || "Anonymous",
          "user_id" => user_id,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "is_correct_guess" => guess_result != :incorrect
        })

        case guess_result do
          {:correct, points, drawer_id} ->
            Games.award_points_to_guesser(user_id, points)
            Games.award_points_to_drawer(drawer_id, div(points, 2))

            broadcast(socket, "correct_guess", %{
              "guesser_id" => user_id,
              "guesser_name" => user.username || "Anonymous",
              "points" => points,
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
            })

          _ ->
            :ok
        end

        {:reply, {:ok, %{status: "message_sent"}}, socket}

      _ ->
        broadcast(socket, "chat_message", %{
          "message" => message,
          "username" => user.username || "Anonymous",
          "user_id" => user_id,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:reply, {:ok, %{status: "message_sent"}}, socket}
    end
  end

  defp check_guess(message, current_word, user_id, drawer_id, game_id) do
    if current_word && user_id != drawer_id do
      normalized_message = String.downcase(String.trim(message))
      normalized_word = String.downcase(current_word)

      if normalized_message == normalized_word do
        time_remaining = Games.get_round_time_remaining(game_id)
        points = Games.calculate_points(time_remaining)
        {:correct, points, drawer_id}
      else
        :incorrect
      end
    else
      :incorrect
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
