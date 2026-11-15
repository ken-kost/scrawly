defmodule Scrawly.Games.StrokeRules do
  @moduledoc """
  What a stroke may look like and how much a canvas may hold. Pure functions.

  Used by `RoomServer` for completed strokes, by `ScrawlyWeb.GameChannel`
  for live stroke chunks and by `ScrawlyWeb.DemoBoardChannel` for both.
  Paths are SVG path data: commands `M L Q C Z` (either case), numbers
  (signs, decimals and exponents) and `,`/space separators, so the client's
  `"M x y Q x y x y ... L x y"` strokes pass.

  The client's stroke engine (stroke_engine.mjs) rounds coordinates to one
  decimal and splits a gesture into a new stroke once its path reaches 7,000
  characters, so no stroke it commits passes ~7,060 bytes: the path cap
  leaves room for that, no more. The canvas budget keeps the stroke list
  (sent in every page load) bounded.

  Also the rate of a drawer's canvas ops (`op_rate_limit/0`) and the round
  replay kept for the score page (`replay/1`).
  """

  @max_path_bytes 8_000
  @max_delta_bytes 2_000
  @max_strokes 500
  @max_canvas_bytes 2_000_000
  @max_stroke_id_bytes 64
  @widths 1..40
  # Stroke ops (commit, undo, clear) a drawer may send per window. The
  # client sends one at a time and waits for its ack, so drawing never comes
  # close; it caps what a forged client can make the room broadcast.
  @op_rate_limit {40, 5_000}
  # A round's replay: at most this many strokes and path bytes, in drawing
  # order. A minute of non-stop drawing is ~100 KB; a typical sketch a
  # fraction of the byte cap.
  @max_replay_strokes 300
  @max_replay_bytes 65_536

  @path_chars ~r/\A[MLQCZmlqcz0-9eE.,\- ]+\z/
  @color ~r/\A#[0-9a-fA-F]{6}\z/

  @type stroke :: %{id: String.t(), path: String.t(), color: String.t(), width: pos_integer}

  def max_path_bytes, do: @max_path_bytes
  def max_delta_bytes, do: @max_delta_bytes
  def max_strokes, do: @max_strokes
  def max_canvas_bytes, do: @max_canvas_bytes
  def max_stroke_id_bytes, do: @max_stroke_id_bytes
  def max_replay_strokes, do: @max_replay_strokes
  def max_replay_bytes, do: @max_replay_bytes

  @doc "`{ops, window_ms}`: the canvas ops a drawer may send per window."
  @spec op_rate_limit() :: {pos_integer, pos_integer}
  def op_rate_limit, do: @op_rate_limit

  @doc "A `#RRGGBB` hex colour (either case)."
  @spec valid_color?(term) :: boolean
  def valid_color?(color) when is_binary(color), do: Regex.match?(@color, color)
  def valid_color?(_color), do: false

  @doc "An integer stroke width in 1..40."
  @spec valid_width?(term) :: boolean
  def valid_width?(width), do: is_integer(width) and width in @widths

  @doc "A completed stroke's path: 1..#{@max_path_bytes} bytes of SVG path characters."
  @spec valid_path?(term) :: boolean
  def valid_path?(path), do: path_data?(path, @max_path_bytes)

  @doc "A live stroke chunk: 1..#{@max_delta_bytes} bytes of SVG path characters."
  @spec valid_delta?(term) :: boolean
  def valid_delta?(delta), do: path_data?(delta, @max_delta_bytes)

  @doc "A client-chosen stroke id: a binary of 1..#{@max_stroke_id_bytes} bytes."
  @spec valid_stroke_id?(term) :: boolean
  def valid_stroke_id?(id),
    do: is_binary(id) and byte_size(id) in 1..@max_stroke_id_bytes

  @doc """
  The ordering tag of a drawer tab's canvas op (commit, undo or clear):
  `{op_epoch, op_seq}` when `op_epoch` is a 1..#{@max_stroke_id_bytes}-byte
  binary (random per page load) and `op_seq` a positive integer (increasing per
  op), otherwise `nil` (no ordering).
  """
  @spec op_tag(term, term) :: {String.t(), pos_integer} | nil
  def op_tag(epoch, seq) do
    if valid_stroke_id?(epoch) and is_integer(seq) and seq > 0, do: {epoch, seq}, else: nil
  end

  @doc """
  Validates `stroke` (a map with `:id`, `:path`, `:color` and `:width`) for
  appending to `strokes`, the canvas so far. The id is the client-chosen stroke
  id (`valid_stroke_id?/1`); undo refers to strokes by it.

  Returns `{:ok, stroke}` with only those four keys, `{:error, :invalid_stroke}`
  when a field is invalid, or `{:error, :stroke_limit}` when the canvas would
  hold more than #{@max_strokes} strokes or #{@max_canvas_bytes} path bytes.
  """
  @spec check_append([stroke], term) :: {:ok, stroke} | {:error, :invalid_stroke | :stroke_limit}
  def check_append(strokes, stroke) when is_list(strokes) do
    with {:ok, stroke} <- normalize(stroke),
         :ok <- check_limits(strokes, stroke) do
      {:ok, stroke}
    end
  end

  @doc """
  A round's drawing as kept for its replay (the Game's `round_details`,
  rendered by the score page): `{strokes, truncated?}`, the strokes in
  drawing order as `%{path, color, width}` (no ids: nothing refers to them
  any more) while they fit in #{@max_replay_strokes} strokes and
  #{@max_replay_bytes} path bytes. `truncated?` tells whether any were left
  out. Accepts atom- or string-keyed maps (a JSONB row) and skips anything
  that isn't a stroke.
  """
  @spec replay([map]) :: {[%{path: String.t(), color: String.t(), width: pos_integer}], boolean}
  def replay(strokes) when is_list(strokes) do
    {kept, _count, _bytes, truncated?} =
      Enum.reduce_while(strokes, {[], 0, 0, false}, fn stroke, {kept, count, bytes, _} ->
        case replay_stroke(stroke) do
          nil ->
            {:cont, {kept, count, bytes, false}}

          %{path: path} = s when count < @max_replay_strokes ->
            size = byte_size(path)

            if bytes + size <= @max_replay_bytes,
              do: {:cont, {[s | kept], count + 1, bytes + size, false}},
              else: {:halt, {kept, count, bytes, true}}

          _over_count ->
            {:halt, {kept, count, bytes, true}}
        end
      end)

    {Enum.reverse(kept), truncated?}
  end

  def replay(_strokes), do: {[], false}

  defp replay_stroke(stroke) when is_map(stroke) do
    path = field(stroke, :path)

    if is_binary(path),
      do: %{
        path: path,
        color: field(stroke, :color) || "#000000",
        width: field(stroke, :width) || 2
      },
      else: nil
  end

  defp replay_stroke(_stroke), do: nil

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @doc "Total path bytes held by `strokes`."
  @spec canvas_bytes([stroke]) :: non_neg_integer
  def canvas_bytes(strokes), do: Enum.reduce(strokes, 0, &(byte_size(&1.path) + &2))

  defp normalize(%{id: id, path: path, color: color, width: width}) do
    if valid_stroke_id?(id) and valid_path?(path) and valid_color?(color) and
         valid_width?(width),
       do: {:ok, %{id: id, path: path, color: color, width: width}},
       else: {:error, :invalid_stroke}
  end

  defp normalize(_stroke), do: {:error, :invalid_stroke}

  defp check_limits(strokes, stroke) do
    if length(strokes) >= @max_strokes or
         canvas_bytes(strokes) + byte_size(stroke.path) > @max_canvas_bytes,
       do: {:error, :stroke_limit},
       else: :ok
  end

  defp path_data?(data, max_bytes) when is_binary(data) do
    byte_size(data) in 1..max_bytes and Regex.match?(@path_chars, data)
  end

  defp path_data?(_data, _max_bytes), do: false
end
