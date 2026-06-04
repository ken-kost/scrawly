defmodule ScrawlyWeb.Presence do
  @moduledoc """
  Phoenix.Presence for the app.

  Used only for the lobby online counter (`online_count/0`, which counts the
  `"lobby:rooms"` topic populated by `LobbyChannel`). Game-channel presence is no
  longer consumed: player join/leave reaches game pages as a RoomServer
  `:room_delta` over Hologram realtime, so `handle_metas/4` is a no-op.
  """
  use Phoenix.Presence,
    otp_app: :scrawly,
    pubsub_server: Scrawly.PubSub

  @impl true
  def init(_opts), do: {:ok, %{}}

  # Game-channel presence no longer rebroadcasts a poll nudge — player join/leave
  # reaches pages as a RoomServer :room_delta. Presence remains only for the
  # lobby online counter (online_count/0 below), so handle_metas is now a no-op.
  @impl true
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
