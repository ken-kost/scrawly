defmodule ScrawlyWeb.GameChannel do
  @moduledoc """
  Thin Phoenix channel — the one realtime path deliberately NOT on Hologram.
  A measured gate (REALTIME_MIGRATION_REPORT.md, "Live stroke chunks: the
  measured gate") kept it: over Hologram Realtime every chunk costs an HTTP
  command, an ack before the next one, and a full page render on every peer.

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
  asking the room (stroke ids are chosen by the client). The cache never
  outlives what it was computed for: the room announces every phase, turn
  and membership change on `Broadcasts.drawing_topic/1` (with each
  `:room_delta`), and the channel drops its verdict then, so the drawer's
  chunks stop at time-up and start right after the word is picked. Chunks must carry a
  stroke id of at most 64 bytes, an integer `seq`, a delta that passes
  `StrokeRules.valid_delta?/1`, and a valid colour and width when present.
  A chunk is relayed with those five fields only: fills (the fill tool's
  shapes) send no chunks, and a `fill` (or anything else) in a forged chunk
  is dropped, so peers only ever draw a chunk as a line.
  A socket's chunks are limited to 60 a second (the client flushes at
  20 Hz, plus early flushes of full chunks); over that they are dropped
  silently.

  NOTE: hard-disconnect player removal is intentionally NOT done here. Reusing
  `terminate` to call `RoomServer.leave/2` would dissolve the room whenever the
  creator reloads (creator-leave dissolves) and cause leave/rejoin flicker on any
  reload. The room removes members without a live tab itself, with a grace
  period, from the layout heartbeat (`RoomServer`'s presence sweep: watchers
  always, players only in the lobby).
  """
  use ScrawlyWeb, :channel

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.{RoomServer, StrokeRules}
  alias Scrawly.Games.RoomServer.Broadcasts

  @verdict_ttl_ms 2_000
  @max_open_strokes 8
  # Chunks per socket per window, sliding.
  @max_chunks 60
  @chunk_window_ms 1_000

  @impl true
  def join("game:" <> room_code, _payload, socket) do
    with {:ok, room} <- find_room(room_code),
         {:ok, user_id} <- socket_user(socket),
         :ok <- check_member(room.id, user_id) do
      Phoenix.PubSub.subscribe(Scrawly.PubSub, Broadcasts.drawing_topic(room.id))

      socket =
        socket
        |> assign(:room_code, room_code)
        |> assign(:room_id, room.id)
        |> assign(:user_id, user_id)
        |> assign(:open_stroke_ids, [])
        |> assign(:chunk_verdict, nil)
        |> assign(:chunk_times, [])

      {:ok, socket}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in("drawing_stroke_chunk", payload, socket) do
    with {:ok, socket} <- take_chunk_slot(socket),
         {:ok, chunk} <- validate_chunk(payload),
         {true, socket} <- chunk_allowed(socket, chunk["stroke_id"]) do
      socket = track_open_stroke(socket, chunk["stroke_id"])
      broadcast_from(socket, "drawing_stroke_chunk", chunk)
      {:noreply, socket}
    else
      {false, socket} -> {:noreply, socket}
      :rate_limited -> {:noreply, socket}
      :invalid -> {:noreply, socket}
    end
  end

  # Unknown events (e.g. the legacy pushes of an old client) are ignored
  # instead of crashing the channel.
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # Who may draw may have changed (phase, turn, membership): the next chunk
  # asks the room again.
  @impl true
  def handle_info({:drawing_changed, _room_id}, socket),
    do: {:noreply, assign(socket, :chunk_verdict, nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

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

  # Admits the chunk when the socket sent fewer than @max_chunks within the
  # window, and records it (invalid ones count too; dropped ones don't).
  defp take_chunk_slot(socket) do
    now = System.monotonic_time(:millisecond)
    # Newest first, so the ones still inside the window are a prefix.
    recent = Enum.take_while(socket.assigns.chunk_times, &(now - &1 < @chunk_window_ms))

    if length(recent) < @max_chunks,
      do: {:ok, assign(socket, :chunk_times, [now | recent])},
      else: :rate_limited
  end

  defp track_open_stroke(socket, stroke_id) do
    open =
      [stroke_id | List.delete(socket.assigns.open_stroke_ids, stroke_id)]
      |> Enum.take(@max_open_strokes)

    assign(socket, :open_stroke_ids, open)
  end
end
