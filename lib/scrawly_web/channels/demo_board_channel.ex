defmodule ScrawlyWeb.DemoBoardChannel do
  @moduledoc """
  Real-time channel for the shared demo canvas on the home page.
  Topic: `demo:board`.

  Inbound events:
    * `"draw"` (`%{path, color, width}`) — append a completed stroke
    * `"clear"` — wipe the board

  Outbound events:
    * `"strokes"` — full snapshot on join (and after clear)
    * `"stroke"` — single newly added stroke
    * `"cleared"` — board was wiped
  """
  use ScrawlyWeb, :channel

  alias Scrawly.Games.DemoBoardServer

  @impl true
  def join("demo:board", _payload, socket) do
    send(self(), :after_join)
    Phoenix.PubSub.subscribe(Scrawly.PubSub, DemoBoardServer.topic())
    {:ok, socket}
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

  def handle_in("clear", _payload, socket) do
    DemoBoardServer.clear()
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}
end
