defmodule ScrawlyWeb.DemoBoardChannel do
  @moduledoc """
  Real-time channel for the shared demo canvas on the home page.
  Topic: `demo:board`.

  Inbound events:
    * `"draw"` (`%{path, color, width}`) — append a completed stroke (legacy)
    * `"stroke_chunk"` (`%{stroke_id, seq, delta, color, width}`) — live in-flight chunk
    * `"stroke_complete"` (`%{stroke_id, path, color, width}`) — final stroke
    * `"clear"` — wipe the board

  Outbound events:
    * `"strokes"` — full snapshot on join (and after clear)
    * `"stroke"` — single newly added stroke (carries `stroke_id` when streamed)
    * `"stroke_chunk"` — relay of another client's in-flight chunk
    * `"stroke_abandon"` — sender disconnected mid-stroke
    * `"cleared"` — board was wiped
  """
  use ScrawlyWeb, :channel

  alias Scrawly.Games.DemoBoardServer

  @impl true
  def join("demo:board", _payload, socket) do
    send(self(), :after_join)
    Phoenix.PubSub.subscribe(Scrawly.PubSub, DemoBoardServer.topic())
    {:ok, assign(socket, :open_stroke_ids, MapSet.new())}
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
  def handle_in("draw", %{"path" => path, "color" => color, "width" => width}, socket)
      when is_binary(path) and is_binary(color) and is_integer(width) do
    if String.length(path) > 0 and String.length(path) < 8_000 do
      DemoBoardServer.add_stroke(%{path: path, color: color, width: width})
    end

    {:noreply, socket}
  end

  # Live in-flight chunks. Broadcast to peers immediately — no GenServer
  # roundtrip on the 20Hz hot path. Persistence happens once on
  # `stroke_complete` below.
  def handle_in("stroke_chunk", payload, socket) do
    stroke_id = payload["stroke_id"]
    delta = payload["delta"] || ""

    if is_binary(stroke_id) and stroke_id != "" and is_binary(delta) and delta != "" and
         byte_size(delta) < 2_000 do
      open = MapSet.put(socket.assigns.open_stroke_ids, stroke_id)
      socket = assign(socket, :open_stroke_ids, open)

      broadcast_from(socket, "stroke_chunk", %{
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

  def handle_in("stroke_complete", payload, socket) do
    stroke_id = payload["stroke_id"]
    path = payload["path"] || ""
    color = payload["color"] || "#000000"
    width = payload["width"] || 2

    if is_binary(stroke_id) and stroke_id != "" and is_binary(path) and
         String.length(path) > 0 and String.length(path) < 8_000 do
      # Persist with stroke_id attached. The `stroke_id` is echoed back to
      # all clients (including the sender) via the existing PubSub `stroke`
      # event so peers can match it against their in-progress overlay and
      # do an atomic remove-overlay + add-to-strokes handoff with no flicker.
      DemoBoardServer.add_stroke(%{
        path: path,
        color: color,
        width: width,
        stroke_id: stroke_id
      })

      open = MapSet.delete(socket.assigns.open_stroke_ids, stroke_id)
      socket = assign(socket, :open_stroke_ids, open)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_in("clear", _payload, socket) do
    DemoBoardServer.clear()
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # If this socket leaves with an in-flight stroke (sender closed the tab,
  # network drop, etc.), tell remaining peers to GC their overlays.
  @impl true
  def terminate(_reason, socket) do
    open = Map.get(socket.assigns, :open_stroke_ids, MapSet.new())

    Enum.each(open, fn stroke_id ->
      broadcast_from(socket, "stroke_abandon", %{"stroke_id" => stroke_id})
    end)

    :ok
  end
end
