defmodule ScrawlyWeb.Presence do
  @moduledoc """
  Provides presence tracking for game channels.

  Implements `handle_metas/4` to broadcast `room_state_changed` via PubSub
  whenever players join or leave a room. This lets all connected channel clients
  immediately poll for fresh state without waiting for the next scheduled tick.
  """
  use Phoenix.Presence,
    otp_app: :scrawly,
    pubsub_server: Scrawly.PubSub

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_metas("game:" <> room_code, %{joins: joins, leaves: leaves}, _presences, state) do
    if map_size(joins) > 0 or map_size(leaves) > 0 do
      # Notify all room-state subscribers so they poll fresh state.
      with {:ok, room} <- Scrawly.Games.get_room_by_code(room_code) do
        Phoenix.PubSub.broadcast(Scrawly.PubSub, "room:#{room.id}", :room_state_changed)
      end
    end

    {:ok, state}
  end

  def handle_metas(_topic, _diff, _presences, state), do: {:ok, state}

  @doc """
  Counts distinct presences across the lobby channel topic.
  Returns 0 if presence is empty or unavailable.
  """
  def online_count do
    try do
      __MODULE__.list("lobby:rooms") |> map_size()
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end
end
