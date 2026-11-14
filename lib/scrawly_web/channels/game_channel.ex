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

  Only members of the room (players and logged-in watchers) may join, and only
  the current drawer's chunks are relayed while the room is `:drawing`. That
  check (`RoomServer.drawing_allowed?/2`) is cached per stroke so the hot path
  makes about one room call per stroke: an `:allow` is reused for the same
  `stroke_id` for 2 s; after a `:deny`, every chunk is dropped for 2 s without
  asking the room (stroke ids are chosen by the client). Chunks must carry a
  stroke id of at most 64 bytes, an integer `seq`, a delta that passes
  `StrokeRules.valid_delta?/1`, and a valid colour and width when present.

  NOTE: hard-disconnect player removal is intentionally NOT done here. Reusing
  `terminate` to call `RoomServer.leave/2` would dissolve the room whenever the
  creator reloads (creator-leave dissolves) and cause leave/rejoin flicker on any
  reload. Disconnected players already linger today (presence only nudged a poll,
  it never removed anyone), so this is no regression; a correct version needs a
  reconnect grace period and is left as a follow-up.
  """
  use ScrawlyWeb, :channel

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.{RoomServer, StrokeRules}

  @verdict_ttl_ms 2_000
  @max_open_strokes 8

  @impl true
  def join("game:" <> room_code, _payload, socket) do
    with {:ok, room} <- find_room(room_code),
         {:ok, user_id} <- socket_user(socket),
         :ok <- check_member(room.id, user_id) do
      socket =
        socket
        |> assign(:room_code, room_code)
        |> assign(:room_id, room.id)
        |> assign(:user_id, user_id)
        |> assign(:open_stroke_ids, [])
        |> assign(:chunk_verdict, nil)

      {:ok, socket}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in("drawing_stroke_chunk", payload, socket) do
    with {:ok, chunk} <- validate_chunk(payload),
         {true, socket} <- chunk_allowed(socket, chunk["stroke_id"]) do
      socket = track_open_stroke(socket, chunk["stroke_id"])
      broadcast_from(socket, "drawing_stroke_chunk", chunk)
      {:noreply, socket}
    else
      {false, socket} -> {:noreply, socket}
      :invalid -> {:noreply, socket}
    end
  end

  # Unknown events (such as the legacy pushes priv/static/game_socket.js still
  # exposes, or an old client) are ignored instead of crashing the channel.
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    socket.assigns
    |> Map.get(:open_stroke_ids, [])
    |> Enum.each(fn stroke_id ->
      broadcast_from(socket, "drawing_stroke_abandon", %{"stroke_id" => stroke_id})
    end)

    :ok
  end

  defp find_room(room_code) do
    case Games.get_room_by_code(room_code) do
      {:ok, room} -> {:ok, room}
      {:error, _} -> {:error, "invalid_room"}
    end
  end

  defp socket_user(socket) do
    with user_id when not is_nil(user_id) <- socket.assigns[:user_id],
         {:ok, %Accounts.User{}} <- Accounts.get_user_by_id(user_id) do
      {:ok, user_id}
    else
      _ -> {:error, "unauthorized"}
    end
  end

  # Players and watchers; a logged-in watcher's id is their user id
  # (`ScrawlyWeb.Auth.actor_key/1`).
  defp check_member(room_id, user_id) do
    if RoomServer.member?(room_id, user_id), do: :ok, else: {:error, "not_member"}
  end

  defp validate_chunk(payload) when is_map(payload) do
    stroke_id = payload["stroke_id"]
    delta = payload["delta"]
    seq = payload["seq"]
    color = Map.get(payload, "color") || "#000000"
    width = Map.get(payload, "width") || 2

    if StrokeRules.valid_stroke_id?(stroke_id) and StrokeRules.valid_delta?(delta) and
         is_integer(seq) and StrokeRules.valid_color?(color) and StrokeRules.valid_width?(width) do
      {:ok,
       %{
         "stroke_id" => stroke_id,
         "seq" => seq,
         "delta" => delta,
         "color" => color,
         "width" => width
       }}
    else
      :invalid
    end
  end

  defp validate_chunk(_payload), do: :invalid

  # Never calls RoomServer.get_state/1: that copies the whole room state.
  defp chunk_allowed(socket, stroke_id) do
    now = System.monotonic_time(:millisecond)

    case socket.assigns[:chunk_verdict] do
      {_id, :deny, at} when now - at < @verdict_ttl_ms ->
        {false, socket}

      {^stroke_id, :allow, at} when now - at < @verdict_ttl_ms ->
        {true, socket}

      _stale_or_other_stroke ->
        allowed? = RoomServer.drawing_allowed?(socket.assigns.room_id, socket.assigns.user_id)
        verdict = if allowed?, do: :allow, else: :deny
        {allowed?, assign(socket, :chunk_verdict, {stroke_id, verdict, now})}
    end
  end

  defp track_open_stroke(socket, stroke_id) do
    open =
      [stroke_id | List.delete(socket.assigns.open_stroke_ids, stroke_id)]
      |> Enum.take(@max_open_strokes)

    assign(socket, :open_stroke_ids, open)
  end
end
