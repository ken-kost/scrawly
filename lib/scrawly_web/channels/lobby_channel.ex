defmodule ScrawlyWeb.LobbyChannel do
  @moduledoc """
  Channel for real-time room list updates on the home page.
  Subscribes to "lobby:rooms" PubSub topic and pushes events to clients
  when rooms are created, players join/leave, or games start/end.

  Tracks every connected lobby client in `ScrawlyWeb.Presence` under the
  "lobby" topic so the header's online counter reflects active sessions.
  """
  use ScrawlyWeb, :channel

  alias ScrawlyWeb.Presence

  @chat_max_messages 4
  @chat_window_ms 5_000

  @impl true
  def join("lobby:rooms", payload, socket) do
    send(self(), :after_join)
    Phoenix.PubSub.subscribe(Scrawly.PubSub, "lobby:rooms")

    username = resolve_username(socket.assigns[:user_id], payload)
    {:ok, assign(socket, :chat_username, username)}
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns[:user_id]

    key =
      cond do
        is_binary(user_id) and user_id != "" -> user_id
        true -> "anon:" <> Integer.to_string(System.unique_integer([:positive]))
      end

    {:ok, _} =
      Presence.track(socket, key, %{
        online_at: System.system_time(:second),
        anonymous: is_nil(user_id) or user_id == ""
      })

    push(socket, "presence_state", Presence.list(socket))

    Phoenix.PubSub.broadcast(Scrawly.PubSub, "lobby:online", :online_count_changed)
    {:noreply, socket}
  end

  def handle_info(:rooms_updated, socket) do
    push(socket, "rooms_updated", %{})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("chat_message", %{"message" => message}, socket)
      when is_binary(message) and byte_size(message) > 0 do
    trimmed = message |> String.trim() |> String.slice(0, 240)

    if trimmed == "" do
      {:reply, {:error, %{reason: "empty_message"}}, socket}
    else
      now = System.monotonic_time(:millisecond)
      timestamps = Map.get(socket.assigns, :chat_timestamps, [])
      recent = Enum.filter(timestamps, &(now - &1 < @chat_window_ms))

      if length(recent) >= @chat_max_messages do
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
      else
        socket = assign(socket, :chat_timestamps, [now | recent])

        broadcast(socket, "chat_message", %{
          "username" => socket.assigns.chat_username,
          "message" => trimmed,
          "is_guest" => is_nil(socket.assigns[:user_id]),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:reply, {:ok, %{status: "sent"}}, socket}
      end
    end
  end

  def handle_in("chat_message", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_message"}}, socket}
  end

  # Allow Phoenix.Presence's auto-broadcast of "presence_diff" to pass through
  # without crashing the channel process.
  @impl true
  def handle_out("presence_diff", payload, socket) do
    push(socket, "presence_diff", payload)
    {:noreply, socket}
  end

  def handle_out(_event, _payload, socket), do: {:noreply, socket}

  defp resolve_username(user_id, payload) when is_binary(user_id) and user_id != "" do
    case Ash.get(Scrawly.Accounts.User, user_id) do
      {:ok, %{username: username}} when is_binary(username) and username != "" -> username
      _ -> guest_username(payload)
    end
  end

  defp resolve_username(_user_id, payload), do: guest_username(payload)

  defp guest_username(%{"guest_nickname" => nick})
       when is_binary(nick) and byte_size(nick) > 0 do
    nick
    |> String.trim()
    |> String.slice(0, 32)
    |> case do
      "" -> generate_guest_nickname()
      n -> n
    end
  end

  defp guest_username(_), do: generate_guest_nickname()

  defp generate_guest_nickname do
    "guest_" <> (System.unique_integer([:positive]) |> Integer.to_string())
  end
end
