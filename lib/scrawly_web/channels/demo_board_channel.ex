defmodule ScrawlyWeb.DemoBoardChannel do
  @moduledoc """
  Real-time channel for the shared demo canvas on the home page.
  Topic: `demo:board`. Kept over Hologram Realtime by a measured gate
  (REALTIME_MIGRATION_REPORT.md, "Live stroke chunks: the measured gate").

  Inbound events:
    * `"stroke_chunk"` (`%{stroke_id, seq, delta, color, width}`) — live in-flight chunk
    * `"stroke_complete"` (`%{stroke_id, path, color, width}`) — final stroke. Replies
      `:ok` when stored, or `{:error, %{reason: "invalid_stroke" | "rate_limited"}}`
      (peers then get `"stroke_abandon"` for its id, if the id itself is valid). The
      sender commits the stroke optimistically and uses the reply to roll it back,
      and the `"stroke"` echo to confirm and order it.
    * `"clear"` — wipe the board

  Any other event is ignored.

  The board is open to visitors without an account, so every event is checked
  and rate-limited per socket (limits in assigns, see `@limits`), with the
  same `Scrawly.Games.StrokeRules` checks as the game: a stroke id of 1..64
  bytes, a path of SVG path characters of at most
  `StrokeRules.max_path_bytes/0` bytes, a chunk delta of at most
  `StrokeRules.max_delta_bytes/0`, `color` `#RRGGBB` and `width` an integer
  in 1..40, in chunks and completed strokes alike; a missing value is
  invalid. Invalid or over-limit chunks and clears are dropped silently. Only
  the socket's 8 newest open strokes are remembered (abandoned for peers
  if it goes away mid-stroke).

  Outbound events:
    * `"strokes"` — full snapshot on every join and rejoin
    * `"stroke"` — single newly added stroke with its `stroke_id`, sent to everyone
      including its sender
    * `"stroke_chunk"` — relay of another client's in-flight chunk
    * `"stroke_abandon"` — a stroke was rejected, or its sender disconnected mid-stroke
    * `"cleared"` — board was wiped
  """
  use ScrawlyWeb, :channel

  alias Scrawly.Games.{DemoBoardServer, StrokeRules}

  # Open strokes remembered per socket (a gesture is one, a split gesture
  # two in a row); like GameChannel.
  @max_open_strokes 8

  # Per-socket sliding windows: {max events, window ms}. The client flushes
  # chunks at 20 Hz (FLUSH_INTERVAL_MS = 50 in demo_board.mjs).
  @limits %{
    clear: {1, 5_000},
    stroke_complete: {20, 1_000},
    stroke_chunk: {40, 1_000}
  }

  @impl true
  def join("demo:board", _payload, socket) do
    send(self(), :after_join)
    Phoenix.PubSub.subscribe(Scrawly.PubSub, DemoBoardServer.topic())

    {:ok,
     socket
     |> assign(:open_stroke_ids, [])
     |> assign(:rate_events, Map.new(@limits, fn {event, _limit} -> {event, []} end))}
  end

  @impl true
  def handle_info(:after_join, socket) do
    push(socket, "strokes", %{strokes: DemoBoardServer.get_strokes()})
    {:noreply, socket}
  end

  def handle_info({:stroke_added, stroke}, socket) do
    push(socket, "stroke", stroke)
    {:noreply, socket}
  end

  def handle_info(:strokes_cleared, socket) do
    push(socket, "cleared", %{})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in(_event, payload, socket) when not is_map(payload), do: {:noreply, socket}

  # Live in-flight chunks. Broadcast to peers immediately — no GenServer
  # roundtrip on the 20Hz hot path. Persistence happens once on
  # `stroke_complete` below.
  def handle_in("stroke_chunk", payload, socket) do
    case take_slot(socket, :stroke_chunk) do
      {:ok, socket} -> {:noreply, relay_chunk(socket, payload)}
      :rate_limited -> {:noreply, socket}
    end
  end

  def handle_in("stroke_complete", payload, socket) do
    stroke_id = payload["stroke_id"]

    case take_slot(socket, :stroke_complete) do
      {:ok, socket} -> complete_stroke(socket, stroke_id, payload)
      :rate_limited -> reject_stroke(socket, stroke_id, "rate_limited")
    end
  end

  def handle_in("clear", _payload, socket) do
    case take_slot(socket, :clear) do
      {:ok, socket} ->
        DemoBoardServer.clear()
        {:noreply, socket}

      :rate_limited ->
        {:noreply, socket}
    end
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # If this socket leaves with an in-flight stroke (sender closed the tab,
  # network drop, etc.), tell remaining peers to GC their overlays.
  @impl true
  def terminate(_reason, socket) do
    open = Map.get(socket.assigns, :open_stroke_ids, [])

    Enum.each(open, fn stroke_id ->
      broadcast_from(socket, "stroke_abandon", %{"stroke_id" => stroke_id})
    end)

    :ok
  end

  defp relay_chunk(socket, payload) do
    stroke_id = payload["stroke_id"]
    delta = payload["delta"]

    with true <- StrokeRules.valid_stroke_id?(stroke_id),
         true <- StrokeRules.valid_delta?(delta),
         {:ok, color, width} <- style(payload) do
      broadcast_from(socket, "stroke_chunk", %{
        "stroke_id" => stroke_id,
        "seq" => if(is_integer(payload["seq"]), do: payload["seq"], else: 0),
        "delta" => delta,
        "color" => color,
        "width" => width
      })

      open =
        [stroke_id | List.delete(socket.assigns.open_stroke_ids, stroke_id)]
        |> Enum.take(@max_open_strokes)

      assign(socket, :open_stroke_ids, open)
    else
      _ -> socket
    end
  end

  defp complete_stroke(socket, stroke_id, payload) do
    path = payload["path"]

    with true <- StrokeRules.valid_stroke_id?(stroke_id),
         true <- StrokeRules.valid_path?(path),
         {:ok, color, width} <- style(payload) do
      # Stored with its stroke_id, which the `stroke` echo carries to every
      # client (the sender included): the sender confirms its pending stroke
      # by id, peers swap their in-progress overlay for it in one step.
      DemoBoardServer.add_stroke(%{
        path: path,
        color: color,
        width: width,
        stroke_id: stroke_id
      })

      {:reply, :ok, forget_open_stroke(socket, stroke_id)}
    else
      _ -> reject_stroke(socket, stroke_id, "invalid_stroke")
    end
  end

  defp reject_stroke(socket, stroke_id, reason) do
    # Peers drop their overlay for it now rather than when this socket ends.
    # Only a valid id can have one (chunks pass the same check).
    if StrokeRules.valid_stroke_id?(stroke_id) do
      broadcast_from(socket, "stroke_abandon", %{"stroke_id" => stroke_id})
    end

    {:reply, {:error, %{reason: reason}}, forget_open_stroke(socket, stroke_id)}
  end

  defp style(%{"color" => color, "width" => width}) do
    if StrokeRules.valid_color?(color) and StrokeRules.valid_width?(width),
      do: {:ok, color, width},
      else: :error
  end

  defp style(_payload), do: :error

  # Admits the event when this socket sent fewer than the event's limit within
  # its window, and records it. Over-limit events don't count; admitted ones
  # do even if they turn out to be invalid.
  defp take_slot(socket, event) do
    {max, window_ms} = Map.fetch!(@limits, event)
    now = System.monotonic_time(:millisecond)
    events = socket.assigns.rate_events
    # Newest first, so the ones still inside the window are a prefix.
    recent = Enum.take_while(Map.fetch!(events, event), &(now - &1 < window_ms))

    if length(recent) < max do
      {:ok, assign(socket, :rate_events, Map.put(events, event, [now | recent]))}
    else
      :rate_limited
    end
  end

  defp forget_open_stroke(socket, stroke_id) do
    assign(socket, :open_stroke_ids, List.delete(socket.assigns.open_stroke_ids, stroke_id))
  end
end
