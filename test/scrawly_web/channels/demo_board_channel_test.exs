defmodule ScrawlyWeb.DemoBoardChannelTest do
  @moduledoc """
  `stroke_complete` replies so the sender can confirm or roll back the stroke
  it committed optimistically; a rejected stroke is not stored and peers get
  `stroke_abandon` for it. Colours and widths are validated and every event is
  rate-limited per socket (the board is open to visitors without an account).

  Who draws is the socket's `board_key` (from a board token, see
  `ScrawlyWeb.BoardTokenTest`): without one a socket only watches. Every
  stroke is stored with its owner; each socket is told which strokes are its
  own (`mine`), `"undo"` removes only the caller's newest gesture, and no
  pushed message ever carries an owner key or a gesture id.

  DemoBoardServer is a global singleton, hence `async: false`.
  """
  use ScrawlyWeb.ChannelCase, async: false

  alias Scrawly.Games.DemoBoardServer
  alias ScrawlyWeb.Components.DrawingToolbar
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

  # Actor keys as ScrawlyWeb.Auth.actor_key/1 makes them.
  @me "anon:1111aaaa2222bbbb"
  @other "anon:3333cccc4444dddd"

  defp join_board(key \\ @me) do
    ScrawlyWeb.UserSocket
    |> socket(nil, %{user_id: nil, board_key: key})
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

    test "the toolbar's colours and sizes and the eraser all work", %{socket: socket} do
      # The slider's ends and some sizes between; the eraser (ERASER in
      # draw_tools.mjs) is white at the slider's size.
      sizes = [DrawingToolbar.min_size(), 4, 17, DrawingToolbar.max_size()]

      styles =
        for(color <- DrawingToolbar.colors(), size <- sizes, do: {color, size}) ++
          for size <- sizes, do: {"#ffffff", size}

      for {{color, width}, i} <- Enum.with_index(styles) do
        # Stay under the per-second stroke and chunk limits (24 colours x 4
        # sizes is more than a second's worth of either).
        if rem(i, 20) == 19 do
          age_rate_events(socket, :stroke_complete, 1_000)
          age_rate_events(socket, :stroke_chunk, 1_000)
        end

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

  # ── Who draws, whose strokes, undo (#42) ─────────────────────────────

  # Every message in the mailbox, whoever it is for (pushes, replies and the
  # broadcasts other sockets receive).
  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The next `n` pushes of `event` to `socket` (told apart by its join_ref),
  # waited for, in order; everything else stays in the mailbox.
  defp pushed(socket, event, n) do
    join_ref = socket.join_ref

    for _ <- 1..n//1 do
      assert_receive %Phoenix.Socket.Message{join_ref: ^join_ref, event: ^event, payload: payload}
      payload
    end
  end

  defp refute_pushed(socket, event) do
    join_ref = socket.join_ref
    refute_receive %Phoenix.Socket.Message{join_ref: ^join_ref, event: ^event}, 50
  end

  defp add_stroke!(socket, id, extra \\ %{}) do
    ref = push(socket, "stroke_complete", Map.merge(stroke(id), extra))
    assert_reply ref, :ok
    id
  end

  defp undo!(socket) do
    ref = push(socket, "undo", %{})
    assert_reply ref, status, reply
    {status, reply}
  end

  defp board_ids, do: Enum.map(DemoBoardServer.get_strokes(), & &1.stroke_id)

  describe "a socket without a board key" do
    setup %{socket: socket} do
      add_stroke!(socket, "d-before")
      {:ok, reply, watcher} = join_board(nil)
      assert reply == %{draw: false}
      assert_push "strokes", %{strokes: [%{stroke_id: "d-before"}]}
      %{watcher: watcher}
    end

    test "the join tells: draw only with a key" do
      assert {:ok, %{draw: true}, _} = join_board()
      assert {:ok, %{draw: false}, _} = join_board(nil)
      assert {:ok, %{draw: false}, _} = join_board("")
    end

    test "watches, but every drawing event is refused", %{socket: socket, watcher: watcher} do
      push(watcher, "stroke_chunk", chunk("d-w-1"))
      ref = push(watcher, "stroke_complete", stroke("d-w-1"))
      assert_reply ref, :error, %{reason: "unauthorized"}
      ref = push(watcher, "undo", %{})
      assert_reply ref, :error, %{reason: "unauthorized"}
      push(watcher, "clear", %{})

      # Handled in order: all of the above is done once this is acked.
      ref = push(watcher, "stroke_complete", stroke("d-w-2"))
      assert_reply ref, :error, %{reason: "unauthorized"}

      refute_broadcast "stroke_chunk", _
      refute_broadcast "stroke_abandon", _
      refute_push "cleared", _
      assert board_ids() == ["d-before"]

      # It still sees the others' strokes, none of them its own.
      add_stroke!(socket, "d-after")
      assert [%{stroke_id: "d-after"} = seen] = pushed(watcher, "stroke", 1)
      refute Map.has_key?(seen, :mine)
    end
  end

  describe "mine" do
    test "each socket is told which strokes are its own, in the echo and the snapshot",
         %{socket: me} do
      {:ok, _, other} = join_board(@other)

      add_stroke!(me, "d-mine-1")
      add_stroke!(other, "d-theirs-1")

      assert [%{stroke_id: "d-mine-1", mine: true}, theirs] = pushed(me, "stroke", 2)
      assert theirs.stroke_id == "d-theirs-1" and not Map.has_key?(theirs, :mine)

      assert [mine_seen, %{stroke_id: "d-theirs-1", mine: true}] = pushed(other, "stroke", 2)
      assert mine_seen.stroke_id == "d-mine-1" and not Map.has_key?(mine_seen, :mine)

      # Another tab of the same visitor (the same key) shares the owner.
      {:ok, _, tab2} = join_board(@me)
      assert [%{strokes: [first, second]}] = pushed(tab2, "strokes", 1)

      assert {first.stroke_id, first[:mine], second.stroke_id, second[:mine]} ==
               {"d-mine-1", true, "d-theirs-1", nil}
    end
  end

  describe "undo" do
    test "removes only the caller's newest stroke; everyone is told its id",
         %{socket: me} do
      {:ok, _, other} = join_board(@other)
      assert_push "strokes", _

      add_stroke!(me, "d-m1")
      add_stroke!(other, "d-o1")
      add_stroke!(me, "d-m2")
      add_stroke!(other, "d-o2")

      assert undo!(me) == {:ok, %{stroke_ids: ["d-m2"]}}
      assert board_ids() == ["d-m1", "d-o1", "d-o2"]
      assert pushed(me, "stroke_removed", 1) == [%{stroke_ids: ["d-m2"]}]
      assert pushed(other, "stroke_removed", 1) == [%{stroke_ids: ["d-m2"]}]

      assert undo!(other) == {:ok, %{stroke_ids: ["d-o2"]}}
      assert undo!(me) == {:ok, %{stroke_ids: ["d-m1"]}}
      assert board_ids() == ["d-o1"]

      assert pushed(other, "stroke_removed", 2) == [
               %{stroke_ids: ["d-o2"]},
               %{stroke_ids: ["d-m1"]}
             ]

      # Nothing of mine left: a no-op, nothing broadcast.
      assert undo!(me) == {:error, %{reason: "nothing_to_undo"}}
      assert board_ids() == ["d-o1"]
      refute_pushed(other, "stroke_removed")
    end

    test "removes every stroke of the newest gesture, whatever came between",
         %{socket: me} do
      {:ok, _, other} = join_board(@other)
      assert_push "strokes", _

      add_stroke!(me, "d-g1-a", %{"gesture" => "g-one"})
      add_stroke!(me, "d-g2-a", %{"gesture" => "g-two"})
      add_stroke!(other, "d-o1", %{"gesture" => "g-two"})
      add_stroke!(me, "d-g2-b", %{"gesture" => "g-two"})
      add_stroke!(me, "d-g2-c", %{"gesture" => "g-two"})

      assert undo!(me) == {:ok, %{stroke_ids: ["d-g2-a", "d-g2-b", "d-g2-c"]}}

      assert board_ids() == ["d-g1-a", "d-o1"],
             "another owner's stroke with that gesture id stays"

      assert undo!(me) == {:ok, %{stroke_ids: ["d-g1-a"]}}
      assert board_ids() == ["d-o1"]
    end

    test "a gesture id is checked like a stroke id; a stroke id already on the board is refused",
         %{socket: socket} do
      for {bad, i} <- Enum.with_index(["", 7, String.duplicate("g", 65), %{}]) do
        ref = push(socket, "stroke_complete", Map.put(stroke("d-bad-g-#{i}"), "gesture", bad))
        assert_reply ref, :error, %{reason: "invalid_stroke"}
      end

      add_stroke!(socket, "d-dup", %{"gesture" => nil})

      {:ok, _, other} = join_board(@other)
      ref = push(other, "stroke_complete", stroke("d-dup", "M 1 1 L 9 9"))
      assert_reply ref, :error, %{reason: "invalid_stroke"}

      assert [%{stroke_id: "d-dup", owner: @me, path: "M 10 20 L 30 40"}] =
               DemoBoardServer.get_strokes()

      # So the other visitor's undo can't name my stroke through its id.
      assert undo!(other) == {:error, %{reason: "nothing_to_undo"}}
    end

    test "is rate-limited per socket: 10 a second", %{socket: socket} do
      for i <- 1..12, do: add_stroke!(socket, "d-u-#{i}")

      for i <- 12..3//-1 do
        assert undo!(socket) == {:ok, %{stroke_ids: ["d-u-#{i}"]}}
      end

      assert undo!(socket) == {:error, %{reason: "rate_limited"}}
      assert board_ids() == ["d-u-1", "d-u-2"]

      {:ok, _, tab2} = join_board(@me)
      assert undo!(tab2) == {:ok, %{stroke_ids: ["d-u-2"]}}, "per socket"

      age_rate_events(socket, :undo, 1_000)
      assert undo!(socket) == {:ok, %{stroke_ids: ["d-u-1"]}}
    end

    test "a stroke the 500 cap trimmed can't be undone", %{socket: me} do
      add_stroke!(me, "d-oldest")

      for i <- 1..DemoBoardServer.max_strokes() do
        :ok =
          DemoBoardServer.add_stroke(%{
            stroke_id: "d-fill-#{i}",
            path: "M 1 1 L 2 2",
            color: "#000000",
            width: 2,
            owner: @other
          })
      end

      assert length(board_ids()) == 500
      refute "d-oldest" in board_ids()
      assert undo!(me) == {:error, %{reason: "nothing_to_undo"}}
      assert length(board_ids()) == 500

      # The newest of mine among the 500 still can.
      add_stroke!(me, "d-newer")
      assert undo!(me) == {:ok, %{stroke_ids: ["d-newer"]}}
    end

    test "the board keeps at most max_bytes/0 path bytes: the oldest strokes go first" do
      big = "M 1 1" <> String.duplicate(" L 2 2", 1_330)
      per = byte_size(big)
      fit = div(DemoBoardServer.max_bytes(), per)

      for i <- 1..(fit + 3) do
        :ok =
          DemoBoardServer.add_stroke(%{
            stroke_id: "d-big-#{i}",
            path: big,
            color: "#000000",
            width: 2,
            owner: @other
          })
      end

      ids = board_ids()
      assert length(ids) == fit
      assert hd(ids) == "d-big-4"
      assert List.last(ids) == "d-big-#{fit + 3}"

      bytes = DemoBoardServer.get_strokes() |> Enum.map(&byte_size(&1.path)) |> Enum.sum()
      assert bytes <= DemoBoardServer.max_bytes()

      # Undo and clear keep the totals in step: the room they free is used
      # again, up to the same limit.
      {:ok, _, me} = join_board(@me)
      add_stroke!(me, "d-mine")
      assert undo!(me) == {:ok, %{stroke_ids: ["d-mine"]}}
      assert length(board_ids()) == fit
      DemoBoardServer.clear()
      _ = DemoBoardServer.get_strokes()

      for i <- 1..fit do
        :ok =
          DemoBoardServer.add_stroke(%{
            stroke_id: "d-again-#{i}",
            path: big,
            color: "#000000",
            width: 2,
            owner: @other
          })
      end

      assert length(board_ids()) == fit
    end

    test "demo_board.mjs trims its store by the board's own limits" do
      source = File.read!("lib/scrawly_web/pages/demo_board.mjs")
      assert source =~ "const MAX_STROKES = #{DemoBoardServer.max_strokes()};"
      assert source =~ "export const MAX_BYTES = #{DemoBoardServer.max_bytes()};"
    end
  end

  describe "fills (#43)" do
    @square "M 101 101 L 299 101 L 299 299 L 101 299 Z M 150 150 L 150 160 L 160 160 L 160 150 Z"

    defp fill(id, overrides \\ %{}) do
      Map.merge(
        %{
          "stroke_id" => id,
          "gesture" => id,
          "path" => @square,
          "color" => "#2563EB",
          "width" => 1,
          "fill" => true
        },
        overrides
      )
    end

    test "a fill is stored, echoed and in the snapshot with fill: true, its width 1",
         %{socket: me} do
      {:ok, _, other} = join_board(@other)
      assert [%{strokes: []}] = pushed(other, "strokes", 1)

      ref = push(me, "stroke_complete", fill("d-fill-1", %{"width" => 33}))
      assert_reply ref, :ok

      expected = %{stroke_id: "d-fill-1", path: @square, color: "#2563EB", width: 1, fill: true}
      assert pushed(me, "stroke", 1) == [Map.put(expected, :mine, true)]
      assert pushed(other, "stroke", 1) == [expected]

      assert [%{stroke_id: "d-fill-1", fill: true, width: 1, owner: @me, gesture: "d-fill-1"}] =
               DemoBoardServer.get_strokes()

      # A line next to it carries no fill key at all.
      add_stroke!(me, "d-line-1")
      {:ok, _, again} = join_board(@other)
      assert [%{strokes: [stored_fill, line]}] = pushed(again, "strokes", 1)
      assert stored_fill == expected
      refute Map.has_key?(line, :fill)
      assert DemoBoardChannel.public_stroke(hd(DemoBoardServer.get_strokes()), nil) == expected
    end

    test "a fill whose path or colour isn't a fill's is rejected, abandoned, not stored",
         %{socket: socket} do
      for {id, bad} <- [
            {"d-badfill-1", %{"path" => "M 1 2 Q 3 4 5 6 Z"}},
            {"d-badfill-2", %{"path" => "m 1 2 l 3 4 z"}},
            {"d-badfill-3", %{"path" => "M 1e3 2 L 3 4 Z"}},
            {"d-badfill-4", %{"path" => "M 1 1 " <> String.duplicate("L 2 2 ", 1_400) <> "Z"}},
            {"d-badfill-5", %{"color" => "blue"}},
            {"d-badfill-6", %{"color" => nil}},
            {"d-badfill-7", %{"fill" => "true"}},
            {"d-badfill-8", %{"fill" => 1}}
          ] do
        ref = push(socket, "stroke_complete", fill(id, bad))
        assert_reply ref, :error, %{reason: "invalid_stroke"}
        assert_broadcast "stroke_abandon", %{"stroke_id" => ^id}
      end

      assert DemoBoardServer.get_strokes() == []
    end

    test "fill: false is a line (a line's rules: its width checked)", %{socket: socket} do
      ref = push(socket, "stroke_complete", Map.put(stroke("d-false-1"), "fill", false))
      assert_reply ref, :ok
      assert_push "stroke", pushed_line
      refute Map.has_key?(pushed_line, :fill)

      ref = push(socket, "stroke_complete", fill("d-false-2", %{"fill" => false, "width" => 99}))
      assert_reply ref, :error, %{reason: "invalid_stroke"}
    end

    test "one undo takes one fill back", %{socket: me} do
      add_stroke!(me, "d-before-fill")
      ref = push(me, "stroke_complete", fill("d-fill-u"))
      assert_reply ref, :ok

      assert undo!(me) == {:ok, %{stroke_ids: ["d-fill-u"]}}
      assert board_ids() == ["d-before-fill"]
    end

    test "a forged chunk with a fill is relayed as a line's chunk, without the flag",
         %{socket: socket} do
      push(socket, "stroke_chunk", chunk("d-chunk-fill", %{"fill" => true, "delta" => @square}))
      assert_broadcast "stroke_chunk", relayed
      refute Map.has_key?(relayed, "fill")
      assert Map.keys(relayed) |> Enum.sort() == ~w(color delta seq stroke_id width)
    end
  end

  test "no pushed message carries an owner key or a gesture id", %{socket: me} do
    user_key = Ecto.UUID.generate()
    {:ok, _, other} = join_board(user_key)

    push(me, "stroke_chunk", chunk("d-key-1"))
    add_stroke!(me, "d-key-1", %{"gesture" => "g-secret-a"})
    add_stroke!(me, "d-key-2", %{"gesture" => "g-secret-a"})
    add_stroke!(other, "d-key-3", %{"gesture" => "g-secret-b"})
    push(other, "stroke_chunk", chunk("d-key-4"))
    ref = push(other, "stroke_complete", stroke("d-key-4", path_of_length(9_000)))
    assert_reply ref, :error, _
    ref = push(other, "stroke_complete", Map.put(stroke("d-key-5"), "gesture", "g-secret-b"))
    assert_reply ref, :ok

    # Snapshots (a rejoin of each), undos, a refusal, a clear.
    {:ok, _, me2} = join_board(@me)
    {:ok, _, other2} = join_board(user_key)
    assert {:ok, %{stroke_ids: ["d-key-1", "d-key-2"]}} = undo!(me2)
    assert {:ok, _} = undo!(other)
    assert {:error, _} = undo!(me)
    push(other2, "clear", %{})

    # "cleared" is each socket's last push: once all four have it, every
    # push before it is in the mailbox too.
    cleared =
      for socket <- [me, other, me2, other2] do
        join_ref = socket.join_ref
        assert_receive %Phoenix.Socket.Message{join_ref: ^join_ref, event: "cleared"} = msg
        msg
      end

    messages = cleared ++ drain()
    assert length(messages) > 20

    for msg <- messages, secret <- [@me, user_key, "g-secret-a", "g-secret-b", "anon:"] do
      refute inspect(msg, limit: :infinity, printable_limit: :infinity) =~ secret,
             "#{secret} in #{inspect(msg)}"
    end
  end
end
