defmodule Scrawly.Games.DemoBoardServer do
  @moduledoc """
  Single shared canvas for the home page. Holds an ordered list of completed
  strokes in memory. State changes are broadcast over an internal PubSub
  topic (`demo:board:state`) which the channel subscribes to alongside its
  standard channel-topic subscription.
  """
  use GenServer

  # Internal PubSub topic for state-change notifications. Distinct from the
  # channel topic ("demo:board") so the channel only has one subscription on
  # any given topic — a double subscription routes `%Broadcast{}` messages
  # through `handle_out/3` and crashes on un-intercepted events.
  @topic "demo:board:state"
  @max_strokes 500

  # ── Client API ─────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Return the current list of strokes."
  def get_strokes, do: GenServer.call(__MODULE__, :get_strokes)

  @doc """
  Append a stroke and broadcast it to subscribers.

  Accepts an optional `:stroke_id` field which is passed through so receivers
  can match the canonical stroke up with any in-progress overlay they were
  showing for it.
  """
  def add_stroke(%{path: _, color: _, width: _} = stroke),
    do: GenServer.cast(__MODULE__, {:add_stroke, stroke})

  @doc "Clear the board and broadcast the change."
  def clear, do: GenServer.cast(__MODULE__, :clear)

  def topic, do: @topic

  # ── Server callbacks ───────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{strokes: []}}

  @impl true
  def handle_call(:get_strokes, _from, state), do: {:reply, state.strokes, state}

  @impl true
  def handle_cast({:add_stroke, stroke}, state) do
    strokes = Enum.take(state.strokes ++ [stroke], -@max_strokes)
    Phoenix.PubSub.broadcast(Scrawly.PubSub, @topic, {:stroke_added, stroke})
    {:noreply, %{state | strokes: strokes}}
  end

  def handle_cast(:clear, state) do
    Phoenix.PubSub.broadcast(Scrawly.PubSub, @topic, :strokes_cleared)
    {:noreply, %{state | strokes: []}}
  end
end
