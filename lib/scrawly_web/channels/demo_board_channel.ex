defmodule ScrawlyWeb.DemoBoardChannel do
  @moduledoc """
  Real-time channel for the shared demo canvas on the home page.
  Topic: `demo:board`.

  Inbound events:
    * `"stroke_chunk"` (`%{stroke_id, seq, delta, color, width}`) — live in-flight chunk
    * `"stroke_complete"` (`%{stroke_id, path, color, width}`) — final stroke. Replies
      `:ok` when stored, or `{:error, %{reason: "invalid_stroke"}}` (peers then get
      `"stroke_abandon"` for its id). The sender commits the stroke optimistically and
      uses the reply to roll it back, and the `"stroke"` echo to confirm and order it.
    * `"clear"` — wipe the board

  Any other event is ignored.

  Outbound events:
    * `"strokes"` — full snapshot on every join and rejoin
    * `"stroke"` — single newly added stroke with its `stroke_id`, sent to everyone
      including its sender
    * `"stroke_chunk"` — relay of another client's in-flight chunk
    * `"stroke_abandon"` — a stroke was rejected, or its sender disconnected mid-stroke
    * `"cleared"` — board was wiped
  """
  use ScrawlyWeb, :channel

  alias Scrawly.Games.DemoBoardServer

  # Exclusive upper bound on a completed stroke's path length. The client
  # splits longer gestures into several strokes below this.
  @max_path_length 8_000

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

  # Live in-flight chunks. Broadcast to peers immediately — no GenServer
  # roundtrip on the 20Hz hot path. Persistence happens once on
  # `stroke_complete` below.
  @impl true
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
         String.length(path) > 0 and String.length(path) < @max_path_length do
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
      # Peers drop their overlay for it now rather than when this socket ends.
      if is_binary(stroke_id) do
        broadcast_from(socket, "stroke_abandon", %{"stroke_id" => stroke_id})
      end

      {:reply, {:error, %{reason: "invalid_stroke"}}, forget_open_stroke(socket, stroke_id)}
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

  defp forget_open_stroke(socket, stroke_id) do
    assign(socket, :open_stroke_ids, MapSet.delete(socket.assigns.open_stroke_ids, stroke_id))
  end
end
