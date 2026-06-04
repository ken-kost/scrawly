defmodule ScrawlyWeb.GameChannel do
  @moduledoc """
  Thin Phoenix channel — the one realtime path deliberately NOT on Hologram.

  It carries only:

    * the ~20Hz live in-progress stroke chunk stream (`drawing_stroke_chunk`),
      broadcast straight to peers with no RoomServer roundtrip, and
    * `terminate/2`, which GCs a drawer's in-flight stroke overlay on a hard
      disconnect (the one behaviour that genuinely needs the socket lifecycle —
      Hologram realtime has no disconnect hook).

  Everything else — room/game/timer state, chat, completed-stroke/clear/undo
  persistence and fan-out, and late-join canvas sync — moved to Hologram realtime
  (`:room_delta`, `:chat_appended`, `:stroke_completed`, `:drawing_cleared`,
  `:drawing_undone`) during the realtime migration.

  NOTE: hard-disconnect player removal is intentionally NOT done here. Reusing
  `terminate` to call `RoomServer.leave/2` would dissolve the room whenever the
  creator reloads (creator-leave dissolves) and cause leave/rejoin flicker on any
  reload. Disconnected players already linger today (presence only nudged a poll,
  it never removed anyone), so this is no regression; a correct version needs a
  reconnect grace period and is left as a follow-up.
  """
  use ScrawlyWeb, :channel

  alias Scrawly.Games

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

  # Live in-progress chunks — broadcast immediately to peers, no RoomServer
  # roundtrip so the GenServer hot path stays clear. The *completed* stroke is
  # persisted + fanned out via the Hologram :complete_stroke command instead.
  @impl true
  def handle_in("drawing_stroke_chunk", payload, socket) do
    stroke_id = payload["stroke_id"]
    delta = payload["delta"] || ""

    if is_binary(stroke_id) and stroke_id != "" and delta != "" do
      open = MapSet.put(Map.get(socket.assigns, :open_stroke_ids, MapSet.new()), stroke_id)
      socket = assign(socket, :open_stroke_ids, open)

      broadcast_from(socket, "drawing_stroke_chunk", %{
        "stroke_id" => stroke_id,
        "seq" => payload["seq"] || 0,
        "delta" => delta,
        "color" => payload["color"] || "#000000",
        "width" => payload["width"] || 2
      })

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # If this socket leaves with an in-flight stroke (drawer closed tab, network
  # drop, etc.), tell remaining peers to GC their overlays so the stroke doesn't
  # visually freeze on their canvas.
  @impl true
  def terminate(_reason, socket) do
    open = Map.get(socket.assigns, :open_stroke_ids, MapSet.new())

    Enum.each(open, fn stroke_id ->
      broadcast_from(socket, "drawing_stroke_abandon", %{"stroke_id" => stroke_id})
    end)

    :ok
  end
end
