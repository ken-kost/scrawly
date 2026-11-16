defmodule Scrawly.Games.DemoBoardServer do
  @moduledoc """
  Single shared canvas for the home page. Holds an ordered list of completed
  strokes in memory, oldest first, at most 500 strokes and 450,000 path bytes
  (the oldest go first, whichever limit a new stroke passes: the board's
  snapshot, sent to every visitor who joins, stays under 500 KB). State
  changes are broadcast over an internal PubSub topic (`demo:board:state`)
  which the channel subscribes to alongside its standard channel-topic
  subscription.

  Every stroke is stored with its `owner` (the drawer's actor key,
  `ScrawlyWeb.Auth.actor_key/1`, from the socket's board token) and its
  `gesture` (the id shared by the strokes one long gesture was split into;
  a stroke alone is its own gesture). Both stay on the server: the internal
  messages carry them to the channel processes, which build every pushed
  payload from the public fields only (`ScrawlyWeb.DemoBoardChannel`).

  A fill (the fill tool's closed shape, `fill: true`, see
  `Scrawly.Games.StrokeRules`) is stored and broadcast like any stroke, its
  flag with it; a fill press is a gesture of its own.

  `undo/1` removes the owner's newest gesture still on the board: every
  stroke of that owner with that gesture id, wherever other strokes came
  between them. A stroke the 500 cap has dropped is gone, so it can't be
  undone.
  """
  use GenServer

  # Internal PubSub topic for state-change notifications. Distinct from the
  # channel topic ("demo:board") so the channel only has one subscription on
  # any given topic — a double subscription routes `%Broadcast{}` messages
  # through `handle_out/3` and crashes on un-intercepted events.
  @topic "demo:board:state"
  @max_strokes 500
  # Path bytes kept: with each stroke's JSON around its path (~90 bytes:
  # id, colour, width), the 500-stroke snapshot stays under 500 KB
  # (notes/files/drawing-benchmarks.md, "Budgets"). demo_board.mjs trims
  # its own store by the same two limits.
  @max_bytes 450_000

  @typedoc """
  A stored stroke (`fill: true` for a fill). `owner` and `gesture` never
  leave the server.
  """
  @type stroke :: %{
          required(:stroke_id) => String.t(),
          required(:path) => String.t(),
          required(:color) => String.t(),
          required(:width) => pos_integer,
          required(:owner) => String.t(),
          required(:gesture) => String.t(),
          optional(:fill) => true
        }

  # ── Client API ─────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  The stored strokes, oldest first, owners and gestures included: for the
  channel (which strips them) and tests, never for a client as they are.
  """
  @spec get_strokes() :: [stroke]
  def get_strokes, do: GenServer.call(__MODULE__, :get_strokes)

  @doc "How many strokes the board keeps (the newest)."
  def max_strokes, do: @max_strokes

  @doc "How many path bytes the board keeps (the newest strokes')."
  def max_bytes, do: @max_bytes

  @doc """
  Appends a stroke and broadcasts `{:stroke_added, stroke}` to the channel
  processes. `stroke_id` is passed through so receivers can match the stored
  stroke with the pending stroke or the overlay they show for it; `gesture`
  defaults to the stroke's own id.

  `{:error, :duplicate}` (nothing stored, nothing broadcast) when a stroke
  with that id is already on the board: clients find strokes by id, so an id
  is never shared, or another visitor's undo could take a stroke off their
  canvases.
  """
  @spec add_stroke(map) :: :ok | {:error, :duplicate}
  def add_stroke(%{path: _, color: _, width: _, stroke_id: _, owner: _} = stroke),
    do: GenServer.call(__MODULE__, {:add_stroke, stroke})

  @doc """
  Removes `owner`'s newest gesture still on the board and broadcasts
  `{:strokes_removed, stroke_ids}`. `{:ok, stroke_ids}` (oldest first), or
  `:none` when none of `owner`'s strokes is on the board (nothing
  broadcast).
  """
  @spec undo(term) :: {:ok, [String.t()]} | :none
  def undo(owner) when is_binary(owner) and owner != "",
    do: GenServer.call(__MODULE__, {:undo, owner})

  def undo(_owner), do: :none

  @doc "Clear the board and broadcast the change."
  def clear, do: GenServer.cast(__MODULE__, :clear)

  def topic, do: @topic

  # ── Server callbacks ───────────────────────────────────────────────

  # The strokes, oldest first, with their count and path bytes kept beside
  # them (the limits are checked without walking the list).
  @impl true
  def init(_), do: {:ok, %{strokes: [], count: 0, bytes: 0}}

  @impl true
  def handle_call(:get_strokes, _from, state), do: {:reply, state.strokes, state}

  def handle_call({:add_stroke, stroke}, _from, state) do
    if Enum.any?(state.strokes, &(&1.stroke_id == stroke.stroke_id)) do
      {:reply, {:error, :duplicate}, state}
    else
      stroke = Map.put(stroke, :gesture, Map.get(stroke, :gesture) || stroke.stroke_id)

      state =
        trim(%{
          state
          | strokes: state.strokes ++ [stroke],
            count: state.count + 1,
            bytes: state.bytes + byte_size(stroke.path)
        })

      Phoenix.PubSub.broadcast(Scrawly.PubSub, @topic, {:stroke_added, stroke})
      {:reply, :ok, state}
    end
  end

  def handle_call({:undo, owner}, _from, state) do
    case state.strokes |> Enum.reverse() |> Enum.find(&(&1.owner == owner)) do
      nil ->
        {:reply, :none, state}

      %{gesture: gesture} ->
        {removed, kept} =
          Enum.split_with(state.strokes, &(&1.owner == owner and &1.gesture == gesture))

        ids = Enum.map(removed, & &1.stroke_id)
        Phoenix.PubSub.broadcast(Scrawly.PubSub, @topic, {:strokes_removed, ids})

        {:reply, {:ok, ids},
         %{
           state
           | strokes: kept,
             count: state.count - length(removed),
             bytes: state.bytes - path_bytes(removed)
         }}
    end
  end

  @impl true
  def handle_cast(:clear, state) do
    Phoenix.PubSub.broadcast(Scrawly.PubSub, @topic, :strokes_cleared)
    {:noreply, %{state | strokes: [], count: 0, bytes: 0}}
  end

  # The oldest strokes go while the board holds too many, or too many path
  # bytes. Clients drop the same ones from their own copies.
  defp trim(%{strokes: [oldest | rest], count: count, bytes: bytes} = state)
       when count > @max_strokes or bytes > @max_bytes,
       do: trim(%{state | strokes: rest, count: count - 1, bytes: bytes - byte_size(oldest.path)})

  defp trim(state), do: state

  defp path_bytes(strokes), do: Enum.reduce(strokes, 0, &(byte_size(&1.path) + &2))
end
