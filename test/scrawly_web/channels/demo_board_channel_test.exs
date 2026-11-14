defmodule ScrawlyWeb.DemoBoardChannelTest do
  @moduledoc """
  `stroke_complete` replies so the sender can confirm or roll back the stroke
  it committed optimistically; a rejected stroke is not stored and peers get
  `stroke_abandon` for it.

  DemoBoardServer is a global singleton, hence `async: false`.
  """
  use ScrawlyWeb.ChannelCase, async: false

  alias Scrawly.Games.DemoBoardServer
  alias ScrawlyWeb.DemoBoardChannel

  setup do
    DemoBoardServer.clear()
    # `clear/0` is a cast; this call returns once it has been applied.
    assert DemoBoardServer.get_strokes() == []
    on_exit(fn -> DemoBoardServer.clear() end)

    {:ok, _reply, socket} = join_board()
    assert_push "strokes", %{strokes: []}

    %{socket: socket}
  end

  defp join_board do
    ScrawlyWeb.UserSocket
    |> socket(nil, %{user_id: nil})
    |> subscribe_and_join(DemoBoardChannel, "demo:board")
  end

  defp stroke(id, path \\ "M 10 20 L 30 40") do
    %{"stroke_id" => id, "path" => path, "color" => "#22C55E", "width" => 4}
  end

  defp path_of_length(n), do: String.pad_trailing("M 1 1", n, " L 2 2")

  test "a valid stroke is acked, echoed to its sender and stored", %{socket: socket} do
    ref = push(socket, "stroke_complete", stroke("d-ok-1"))

    assert_reply ref, :ok

    assert_push "stroke", %{
      stroke_id: "d-ok-1",
      path: "M 10 20 L 30 40",
      color: "#22C55E",
      width: 4
    }

    assert [%{stroke_id: "d-ok-1"}] = DemoBoardServer.get_strokes()
  end

  test "a 7,999-character path is accepted", %{socket: socket} do
    path = path_of_length(7_999)
    ref = push(socket, "stroke_complete", stroke("d-max-1", path))

    assert_reply ref, :ok
    assert_push "stroke", %{stroke_id: "d-max-1", path: ^path}
  end

  test "a path of 8,000+ characters is rejected, abandoned for peers and not stored",
       %{socket: socket} do
    for {id, length} <- [{"d-long-1", 8_000}, {"d-long-2", 20_000}] do
      ref = push(socket, "stroke_complete", stroke(id, path_of_length(length)))

      assert_reply ref, :error, %{reason: "invalid_stroke"}
      assert_broadcast "stroke_abandon", %{"stroke_id" => ^id}
    end

    refute_push "stroke", _
    assert DemoBoardServer.get_strokes() == []
  end

  test "an empty or missing path is rejected and abandoned", %{socket: socket} do
    ref = push(socket, "stroke_complete", stroke("d-empty-1", ""))
    assert_reply ref, :error, %{reason: "invalid_stroke"}
    assert_broadcast "stroke_abandon", %{"stroke_id" => "d-empty-1"}

    ref = push(socket, "stroke_complete", %{"stroke_id" => "d-nopath-1"})
    assert_reply ref, :error, %{reason: "invalid_stroke"}
    assert_broadcast "stroke_abandon", %{"stroke_id" => "d-nopath-1"}

    assert DemoBoardServer.get_strokes() == []
  end

  test "a stroke without a binary id is rejected without an abandon", %{socket: socket} do
    for payload <- [Map.delete(stroke(nil), "stroke_id"), stroke(42), stroke("")] do
      ref = push(socket, "stroke_complete", payload)
      assert_reply ref, :error, %{reason: "invalid_stroke"}
    end

    # Only the "" id is a binary, so only it is abandoned.
    assert_broadcast "stroke_abandon", %{"stroke_id" => ""}
    refute_broadcast "stroke_abandon", _
    assert DemoBoardServer.get_strokes() == []
  end

  test "a rejected stroke is no longer open, so leaving doesn't abandon it again",
       %{socket: socket} do
    id = "d-open-1"

    push(socket, "stroke_chunk", %{
      "stroke_id" => id,
      "seq" => 1,
      "delta" => "M 1 1 L 2 2",
      "color" => "#000000",
      "width" => 2
    })

    assert_broadcast "stroke_chunk", %{"stroke_id" => ^id}
    assert MapSet.member?(:sys.get_state(socket.channel_pid).assigns.open_stroke_ids, id)

    ref = push(socket, "stroke_complete", stroke(id, path_of_length(9_000)))
    assert_reply ref, :error, %{reason: "invalid_stroke"}
    assert_broadcast "stroke_abandon", %{"stroke_id" => ^id}
    assert :sys.get_state(socket.channel_pid).assigns.open_stroke_ids == MapSet.new()

    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok
    refute_broadcast "stroke_abandon", _
  end

  test "an accepted stroke is no longer open", %{socket: socket} do
    push(socket, "stroke_chunk", %{"stroke_id" => "d-open-2", "delta" => "M 1 1"})
    assert_broadcast "stroke_chunk", %{"stroke_id" => "d-open-2"}

    ref = push(socket, "stroke_complete", stroke("d-open-2"))
    assert_reply ref, :ok
    assert :sys.get_state(socket.channel_pid).assigns.open_stroke_ids == MapSet.new()
  end

  test "the legacy draw event is ignored", %{socket: socket} do
    push(socket, "draw", %{"path" => "M 1 1 L 2 2", "color" => "#000000", "width" => 2})

    # Events are handled in order, so "draw" is done once this is acked.
    ref = push(socket, "stroke_complete", stroke("d-after-draw"))
    assert_reply ref, :ok
    assert_push "stroke", %{stroke_id: "d-after-draw"}
    refute_push "stroke", _

    assert [%{stroke_id: "d-after-draw"}] = DemoBoardServer.get_strokes()
  end

  test "the join snapshot carries stroke ids", %{socket: socket} do
    ref = push(socket, "stroke_complete", stroke("d-snap-1"))
    assert_reply ref, :ok
    assert_push "stroke", %{stroke_id: "d-snap-1"}

    {:ok, _reply, _other} = join_board()
    assert_push "strokes", %{strokes: [%{stroke_id: "d-snap-1", path: "M 10 20 L 30 40"}]}
  end
end
