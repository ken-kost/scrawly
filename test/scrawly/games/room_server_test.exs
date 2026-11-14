defmodule Scrawly.Games.RoomServerTest do
  @moduledoc """
  The canvas as an ordered, idempotent op log: strokes are kept by id, undo
  removes the given id, and each drawer tab's ops carry `{op_epoch, op_seq}`
  so a resent or late op is ignored. The stored pair resets every round.

  The pure cases drive `handle_call/3` on hand-built states; the round reset
  runs against a live room.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.RoomServer

  @moduletag :capture_log

  @drawer "drawer-id"

  defp stroke(n), do: %{id: "s-#{n}", path: "M #{n} 2 L 3 4", color: "#d63838", width: 5}

  defp room(attrs \\ []) do
    struct!(
      %RoomServer{
        room_id: "TEST-room-#{System.unique_integer([:positive])}",
        status: :playing,
        creator_id: @drawer,
        game_id: "TEST-game",
        phase: :drawing,
        current_round: 1,
        current_drawer_id: @drawer,
        current_word: "zzyzx",
        players: [%{id: @drawer, username: "D"}, %{id: "player-id", username: "P"}],
        drawing_strokes: []
      },
      attrs
    )
  end

  defp call(state, msg) do
    {:reply, reply, new_state} = RoomServer.handle_call(msg, {self(), make_ref()}, state)
    {reply, new_state}
  end

  defp append(state, stroke, op \\ nil), do: call(state, {:append_drawing, @drawer, stroke, op})
  defp undo(state, id, op \\ nil), do: call(state, {:undo_drawing, @drawer, id, op})
  defp clear(state, op \\ nil), do: call(state, {:clear_drawing, @drawer, op})

  describe "append is idempotent by id" do
    test "a stroke id the room already holds changes nothing" do
      {:ok, state} = append(room(), stroke(1))

      assert {:duplicate, ^state} = append(state, stroke(1))
      assert {:duplicate, ^state} = append(state, %{stroke(1) | path: "M 9 9"})
      assert state.drawing_strokes == [stroke(1)]
    end

    test "a held id wins over validation and the stroke limit" do
      full = room(drawing_strokes: Enum.map(1..500, &stroke/1))

      assert {:duplicate, ^full} = append(full, stroke(7))
      assert {:duplicate, ^full} = append(full, %{stroke(7) | color: "red"})
    end
  end

  describe "undo removes the given id" do
    test "only that stroke, wherever it is" do
      state = room(drawing_strokes: [stroke(1), stroke(2), stroke(3)])

      assert {{:ok, [s1, s3]}, undone} = undo(state, "s-2")
      assert [s1, s3] == [stroke(1), stroke(3)]
      assert undone.drawing_strokes == [stroke(1), stroke(3)]
      assert undone.version == state.version + 1

      assert {{:ok, [_, _]}, _} = undo(state, "s-3")
    end

    test "an unknown or missing id changes nothing" do
      state = room(drawing_strokes: [stroke(1)])

      for id <- ["s-404", nil, 42, ""] do
        assert {:duplicate, ^state} = undo(state, id)
      end
    end
  end

  describe "a stale or duplicate {op_epoch, op_seq}" do
    test "is ignored for every op kind" do
      {:ok, state} = append(room(), stroke(1), {"e1", 5})
      assert state.stroke_op == {"e1", 5}

      for seq <- [5, 4, 1] do
        assert {:duplicate, ^state} = append(state, stroke(2), {"e1", seq})
        assert {:duplicate, ^state} = undo(state, "s-1", {"e1", seq})
        assert {:duplicate, ^state} = clear(state, {"e1", seq})
      end

      assert {:ok, next} = append(state, stroke(2), {"e1", 6})
      assert next.drawing_strokes == [stroke(1), stroke(2)]
      assert next.stroke_op == {"e1", 6}
    end

    test "applies ops in seq order and keeps the last applied pair" do
      {:ok, state} = append(room(), stroke(1), {"e1", 1})
      {:ok, state} = append(state, stroke(2), {"e1", 2})
      {{:ok, [_]}, state} = undo(state, "s-2", {"e1", 3})
      {:ok, state} = clear(state, {"e1", 4})
      {:ok, state} = append(state, stroke(3), {"e1", 5})

      assert state.drawing_strokes == [stroke(3)]
      assert state.stroke_op == {"e1", 5}

      # The resend of the undo arrives last: the stroke stays.
      assert {:duplicate, ^state} = undo(state, "s-3", {"e1", 3})
    end

    test "a new epoch (a reloaded drawer tab) starts its own sequence" do
      {:ok, state} = append(room(), stroke(1), {"e1", 40})

      assert {:ok, state} = append(state, stroke(2), {"e2", 1})
      assert state.stroke_op == {"e2", 1}
      assert {:duplicate, ^state} = append(state, stroke(3), {"e2", 1})
    end

    test "ops without a pair are never ordered and don't touch the stored one" do
      {:ok, state} = append(room(), stroke(1), {"e1", 3})

      assert {:ok, state} = append(state, stroke(2))
      assert {:ok, state} = clear(state)
      assert state.stroke_op == {"e1", 3}
    end

    test "rejected and denied ops don't advance the pair" do
      {:ok, state} = append(room(), stroke(1), {"e1", 1})

      {{:error, :invalid_stroke, _}, state} =
        append(state, %{stroke(2) | color: "red"}, {"e1", 2})

      assert state.stroke_op == {"e1", 1}

      {{:error, :not_drawer}, state} =
        call(state, {:append_drawing, "player-id", stroke(3), {"e1", 3}})

      assert state.stroke_op == {"e1", 1}

      assert {:ok, _} = append(state, stroke(2), {"e1", 2})
    end
  end

  describe "the stored pair resets each round" do
    setup do
      creator = create_user()
      player = create_user()
      room = start_room(creator)
      {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})
      seed_test_words()

      %{game_id: game_id} = start_drawing!(room, creator)
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)

      %{room: room, creator: creator, player: player, game_id: game_id, pid: pid}
    end

    test "on the next round's word choice and on the word commit", ctx do
      assert RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(1), {"e1", 7}) == :ok
      assert :sys.get_state(ctx.pid).stroke_op == {"e1", 7}

      Games.stop_round_timer(ctx.game_id)
      send(ctx.pid, {:round_ended, %{reason: :time_up}})
      send(ctx.pid, :auto_advance_round)

      choosing = :sys.get_state(ctx.pid)
      assert %{phase: :choosing, current_round: 2, drawing_strokes: [], stroke_op: nil} = choosing
      assert choosing.current_drawer_id == ctx.player.id

      :sys.replace_state(ctx.pid, &%{&1 | stroke_op: {"e9", 9}})
      [word | _] = choosing.word_choices
      assert {:ok, %{phase: :drawing}} = RoomServer.choose_word(ctx.room.id, ctx.player.id, word)
      assert :sys.get_state(ctx.pid).stroke_op == nil

      # The new drawer's first op is applied whatever the old pair was.
      assert RoomServer.append_drawing(ctx.room.id, ctx.player.id, stroke(2), {"e1", 1}) == :ok
    end

    test "when the game ends", ctx do
      assert RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(1), {"e1", 7}) == :ok

      assert {:ok, _} = RoomServer.end_game(ctx.room.id)
      assert %{drawing_strokes: [], stroke_op: nil} = :sys.get_state(ctx.pid)
    end
  end
end
