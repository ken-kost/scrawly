defmodule ScrawlyWeb.DemoBoardChannelTest do
  @moduledoc """
  `stroke_complete` replies so the sender can confirm or roll back the stroke
  it committed optimistically; a rejected stroke is not stored and peers get
  `stroke_abandon` for it. Colours and widths are validated and every event is
  rate-limited per socket (the board is open to visitors without an account).

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

  defp chunk(id, overrides \\ %{}) do
    Map.merge(
      %{
        "stroke_id" => id,
        "seq" => 1,
        "delta" => "M 1 1 L 2 2",
        "color" => "#000000",
        "width" => 2
      },
      overrides
    )
  end

  # Events are handled in order: once this stroke is acked, everything pushed
  # before it has been handled too.
  defp sync!(socket) do
    id = "d-sync-#{System.unique_integer([:positive])}"
    ref = push(socket, "stroke_complete", stroke(id))
    assert_reply ref, :ok
    assert_push "stroke", %{stroke_id: ^id}
    id
  end

  # Moves this socket's recorded events for `event` `ms` into the past.
  defp age_rate_events(socket, event, ms) do
    :sys.replace_state(socket.channel_pid, fn state ->
      events =
        Map.update!(state.assigns.rate_events, event, fn ts -> Enum.map(ts, &(&1 - ms)) end)

      Phoenix.Socket.assign(state, :rate_events, events)
    end)
  end

  @bad_colors ["red", "#fff", "#GGGGGG", "#0000000", "000000", "#00000 ", 123, nil, %{}]
  @bad_widths ["4", 4.0, 0, 41, -2, nil, [4]]
  @palette [
    "#000000",
    "#EF4444",
    "#F97316",
    "#EAB308",
    "#22C55E",
    "#3B82F6",
    "#A855F7",
    "#EC4899"
  ]

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

  test "a path over 8,000 bytes is rejected, abandoned for peers and not stored",
       %{socket: socket} do
    for {id, length} <- [{"d-long-1", 8_001}, {"d-long-2", 20_000}] do
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

  test "a stroke without a valid id is rejected without an abandon", %{socket: socket} do
    for payload <- [
          Map.delete(stroke(nil), "stroke_id"),
          stroke(42),
          stroke(""),
          stroke(String.duplicate("i", 65))
        ] do
      ref = push(socket, "stroke_complete", payload)
      assert_reply ref, :error, %{reason: "invalid_stroke"}
    end

    # No peer can hold an overlay for an id no chunk could carry.
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
    assert id in :sys.get_state(socket.channel_pid).assigns.open_stroke_ids

    ref = push(socket, "stroke_complete", stroke(id, path_of_length(9_000)))
    assert_reply ref, :error, %{reason: "invalid_stroke"}
    assert_broadcast "stroke_abandon", %{"stroke_id" => ^id}
    assert :sys.get_state(socket.channel_pid).assigns.open_stroke_ids == []

    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok
    refute_broadcast "stroke_abandon", _
  end

  test "an accepted stroke is no longer open", %{socket: socket} do
    push(socket, "stroke_chunk", chunk("d-open-2", %{"delta" => "M 1 1"}))
    assert_broadcast "stroke_chunk", %{"stroke_id" => "d-open-2"}

    ref = push(socket, "stroke_complete", stroke("d-open-2"))
    assert_reply ref, :ok
    assert :sys.get_state(socket.channel_pid).assigns.open_stroke_ids == []
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

  describe "colour and width" do
    test "a stroke with a non-hex colour or a bad width is rejected, abandoned and not stored",
         %{socket: socket} do
      payloads =
        Enum.map(@bad_colors, &Map.put(stroke("d-c"), "color", &1)) ++
          Enum.map(@bad_widths, &Map.put(stroke("d-w"), "width", &1)) ++
          [Map.delete(stroke("d-nc"), "color"), Map.delete(stroke("d-nw"), "width")]

      for {payload, i} <- Enum.with_index(payloads) do
        id = "d-style-#{i}"
        ref = push(socket, "stroke_complete", Map.put(payload, "stroke_id", id))

        assert_reply ref, :error, %{reason: "invalid_stroke"}
        assert_broadcast "stroke_abandon", %{"stroke_id" => ^id}
      end

      refute_push "stroke", _
      assert DemoBoardServer.get_strokes() == []
    end

    test "chunks with a non-hex colour or a bad width are not relayed or opened",
         %{socket: socket} do
      payloads =
        Enum.map(@bad_colors, &chunk("d-bad-chunk", %{"color" => &1})) ++
          Enum.map(@bad_widths, &chunk("d-bad-chunk", %{"width" => &1})) ++
          [Map.delete(chunk("d-bad-chunk"), "color"), Map.delete(chunk("d-bad-chunk"), "width")]

      for payload <- payloads, do: push(socket, "stroke_chunk", payload)

      sync!(socket)
      refute_broadcast "stroke_chunk", _
      assert :sys.get_state(socket.channel_pid).assigns.open_stroke_ids == []
    end

    test "palette colours, widths 2/4/8 and the eraser still work", %{socket: socket} do
      styles =
        for(color <- @palette, width <- [2, 4, 8], do: {color, width}) ++ [{"#ffffff", 18}]

      for {{color, width}, i} <- Enum.with_index(styles) do
        # Stay under the per-second stroke limit.
        if rem(i, 20) == 19, do: age_rate_events(socket, :stroke_complete, 1_000)

        id = "d-pal-#{i}"
        push(socket, "stroke_chunk", chunk(id, %{"color" => color, "width" => width}))

        assert_broadcast "stroke_chunk", %{
          "stroke_id" => ^id,
          "color" => ^color,
          "width" => ^width
        }

        ref =
          push(socket, "stroke_complete", %{stroke(id) | "color" => color, "width" => width})

        assert_reply ref, :ok
        assert_push "stroke", %{stroke_id: ^id, color: ^color, width: ^width}
      end

      assert length(DemoBoardServer.get_strokes()) == length(styles)
    end

    test "a relayed chunk carries only the normalized keys", %{socket: socket} do
      push(socket, "stroke_chunk", chunk("d-norm", %{"seq" => "x", "extra" => "<script>"}))

      assert_broadcast "stroke_chunk", relayed

      assert relayed == %{
               "stroke_id" => "d-norm",
               "seq" => 0,
               "delta" => "M 1 1 L 2 2",
               "color" => "#000000",
               "width" => 2
             }
    end

    test "a non-map payload is ignored", %{socket: socket} do
      push(socket, "stroke_complete", ["not", "a", "map"])
      push(socket, "clear", "nope")
      sync!(socket)

      refute_push "cleared", _
      assert [_] = DemoBoardServer.get_strokes()
    end
  end

  describe "rate limits" do
    test "a second clear within 5 s is ignored", %{socket: socket} do
      sync!(socket)
      push(socket, "clear", %{})
      assert_push "cleared", %{}

      id = sync!(socket)
      push(socket, "clear", %{})
      sync!(socket)

      refute_push "cleared", _
      assert [%{stroke_id: ^id}, _] = DemoBoardServer.get_strokes()

      age_rate_events(socket, :clear, 5_000)
      push(socket, "clear", %{})
      assert_push "cleared", %{}
    end

    test "the 21st stroke within a second is rejected as rate_limited and abandoned",
         %{socket: socket} do
      for i <- 1..20 do
        ref = push(socket, "stroke_complete", stroke("d-rate-#{i}"))
        assert_reply ref, :ok
      end

      ref = push(socket, "stroke_complete", stroke("d-rate-21"))
      assert_reply ref, :error, %{reason: "rate_limited"}
      assert_broadcast "stroke_abandon", %{"stroke_id" => "d-rate-21"}

      assert length(DemoBoardServer.get_strokes()) == 20
      refute Enum.any?(DemoBoardServer.get_strokes(), &(&1.stroke_id == "d-rate-21"))

      # Over-limit strokes don't count, so the window frees up on time.
      age_rate_events(socket, :stroke_complete, 1_000)
      ref = push(socket, "stroke_complete", stroke("d-rate-22"))
      assert_reply ref, :ok
    end

    test "chunks over 40 per second are dropped", %{socket: socket} do
      for i <- 1..41, do: push(socket, "stroke_chunk", chunk("d-chunks", %{"seq" => i}))

      for i <- 1..40, do: assert_broadcast("stroke_chunk", %{"seq" => ^i})
      sync!(socket)
      refute_broadcast "stroke_chunk", _

      age_rate_events(socket, :stroke_chunk, 1_000)
      push(socket, "stroke_chunk", chunk("d-chunks", %{"seq" => 42}))
      assert_broadcast "stroke_chunk", %{"seq" => 42}
    end

    test "limits are per socket", %{socket: socket} do
      push(socket, "clear", %{})
      assert_push "cleared", %{}

      {:ok, _reply, other} = join_board()
      assert_push "strokes", %{strokes: []}

      push(other, "clear", %{})
      # Both sockets receive the second clear.
      assert_push "cleared", %{}
      assert_push "cleared", %{}
    end
  end

  # QA G2: the board is open to visitors without an account, so its strokes
  # and chunks pass the same StrokeRules checks as the game's.
  describe "StrokeRules validation (QA G2)" do
    test "a stroke id over 64 bytes is rejected, stored nowhere", %{socket: socket} do
      id = String.duplicate("i", 65)
      ref = push(socket, "stroke_complete", stroke(id))

      assert_reply ref, :error, %{reason: "invalid_stroke"}
      assert DemoBoardServer.get_strokes() == []

      ref = push(socket, "stroke_complete", stroke(String.duplicate("i", 64)))
      assert_reply ref, :ok
    end

    test "a path with characters outside SVG path data is rejected", %{socket: socket} do
      for {path, i} <- Enum.with_index(["M 1 1 L 2 2 <x>", "M 1 1 L 2 2\n", "M 1 1 \u00e9"]) do
        ref = push(socket, "stroke_complete", stroke("d-chars-#{i}", path))
        assert_reply ref, :error, %{reason: "invalid_stroke"}
      end

      # 7,000 two-byte characters: under 8,000 characters, 14,000 bytes.
      ref = push(socket, "stroke_complete", stroke("d-bytes", String.duplicate("\u00e9", 7_000)))
      assert_reply ref, :error, %{reason: "invalid_stroke"}

      assert DemoBoardServer.get_strokes() == []
    end

    test "chunks need a stroke id of at most 64 bytes and a valid delta", %{socket: socket} do
      bad = [
        chunk(String.duplicate("i", 65)),
        chunk("d-bad-delta", %{"delta" => "M 1 1 <script>"}),
        chunk("d-bad-delta", %{"delta" => String.duplicate("1", 2_001)}),
        chunk("d-bad-delta", %{"delta" => String.duplicate("\u00e9", 1_000)})
      ]

      for payload <- bad, do: push(socket, "stroke_chunk", payload)
      sync!(socket)
      refute_broadcast "stroke_chunk", _
      assert :sys.get_state(socket.channel_pid).assigns.open_stroke_ids == []

      push(
        socket,
        "stroke_chunk",
        chunk("d-max-delta", %{"delta" => String.duplicate("1", 2_000)})
      )

      assert_broadcast "stroke_chunk", %{"stroke_id" => "d-max-delta"}
    end

    test "only the 8 newest open strokes are remembered", %{socket: socket} do
      ids = for i <- 1..30, do: "d-open-many-#{i}"
      for id <- ids, do: push(socket, "stroke_chunk", chunk(id))
      sync!(socket)

      open = :sys.get_state(socket.channel_pid).assigns.open_stroke_ids
      assert Enum.sort(open) == Enum.sort(Enum.take(Enum.reverse(ids), 8))

      Process.unlink(socket.channel_pid)
      ref = leave(socket)
      assert_reply ref, :ok

      for id <- Enum.take(Enum.reverse(ids), 8),
          do: assert_broadcast("stroke_abandon", %{"stroke_id" => ^id})

      refute_broadcast "stroke_abandon", _
    end
  end
end
