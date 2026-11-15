defmodule Scrawly.Games.RoomServerTest do
  @moduledoc """
  The canvas as an ordered, idempotent op log: strokes are kept by id, undo
  removes the given id, and each drawer tab's ops carry `{op_epoch, op_seq}`
  so a resent or late op is ignored. The stored pair resets every round.

  Round timing: the room keeps monotonic deadlines instead of a ticking
  `time_left`, reveals hint stages from its own `{:hint_reveal, ...}`
  messages and acts on a time-up only for its current game, round and
  `:drawing` phase.

  The pure cases drive `handle_call/3` / `handle_info/2` on hand-built
  states; the round reset and the broadcast count run against a live room.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.{RoomServer, Scoring, WordHints}

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

      assert {:ok, undone} = undo(state, "s-2")
      assert undone.drawing_strokes == [stroke(1), stroke(3)]
      assert undone.seq == state.seq + 1

      assert {:ok, %{drawing_strokes: [_, _]}} = undo(state, "s-3")
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
      {:ok, state} = undo(state, "s-2", {"e1", 3})
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

      assert expire_round!(ctx.room).phase == :round_end
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

  # ── Round timing ──────────────────────────────────────────────────────

  @game "TEST-game"
  @guesser "player-id"
  @time_up %{game_id: @game, round: 1, reason: :time_up}

  defp drawing(attrs \\ []) do
    room(
      [
        current_word: "elephant",
        round_duration: 60,
        round_active: true,
        round_deadline: System.monotonic_time(:millisecond) + 60_000,
        hint_stage: 0,
        players: [
          %{id: @drawer, username: "D", score: 0},
          %{id: @guesser, username: "P", score: 0}
        ],
        round_start_scores: %{@drawer => 0, @guesser => 0}
      ] ++ attrs
    )
  end

  defp info(state, msg) do
    {:noreply, new_state} = RoomServer.handle_info(msg, state)
    new_state
  end

  defp subscribe(room_id) do
    Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room_id}))
  end

  defp flush_broadcasts do
    receive do
      {:broadcast_action, _, _, _, _} -> flush_broadcasts()
    after
      0 -> :ok
    end
  end

  defp score(state, id), do: Enum.find(state.players, &(&1.id == id)).score
  defp times_up(state), do: Enum.count(state.chat_messages, &(&1.message =~ "Time's up"))

  describe "time helpers" do
    test "round time is computed from the deadline, seconds rounded up" do
      state = drawing(round_deadline: 10_000)

      assert RoomServer.round_remaining_ms(state, 0) == 10_000
      assert RoomServer.time_left(state, 0) == 10
      assert RoomServer.time_left(state, 500) == 10
      assert RoomServer.time_left(state, 9_001) == 1
      assert RoomServer.time_left(state, 10_000) == 0
      assert RoomServer.round_remaining_ms(state, 12_000) == 0
      assert RoomServer.time_left(drawing(round_deadline: nil)) == 0
    end

    test "choice time is computed from the choice deadline" do
      state = room(phase: :choosing, choice_deadline: 15_000)

      assert RoomServer.choice_remaining_ms(state, 1_000) == 14_000
      assert RoomServer.choice_remaining_ms(state, 16_000) == 0
      assert RoomServer.choice_remaining_ms(room(choice_deadline: nil)) == 0
    end

    test "a guess scores with the seconds left on the round deadline" do
      now = System.monotonic_time(:millisecond)

      {{:ok, {:correct, pts}}, _} =
        call(drawing(round_deadline: now + 30_000), {:submit_message, @guesser, "elephant"})

      assert pts == Scoring.guesser_points(30, 60, order: 1)

      {{:ok, {:correct, late}}, _} =
        call(drawing(round_deadline: now - 1), {:submit_message, @guesser, "elephant"})

      assert late == Scoring.guesser_points(0, 60, order: 1)
    end
  end

  describe "{:hint_reveal, game_id, round, stage}" do
    test "reveals the stage and broadcasts the new mask" do
      state = drawing()
      subscribe(state.room_id)

      revealed = info(state, {:hint_reveal, @game, 1, 1})

      assert revealed.hint_stage == 1
      assert revealed.seq == state.seq + 1
      assert_received {:broadcast_action, _, :room_delta, delta, _}
      assert delta.word_display == WordHints.hint_for_stage("elephant", 1)
      assert delta.word_display != WordHints.hint_for_stage("elephant", 0)
      refute inspect(delta) =~ "elephant"

      assert info(revealed, {:hint_reveal, @game, 1, 2}).hint_stage == 2
      assert_received {:broadcast_action, _, :room_delta, %{word_display: stage2}, _}
      assert stage2 == WordHints.hint_for_stage("elephant", 2)
    end

    test "a stage that leaves the mask unchanged broadcasts nothing" do
      state = drawing(current_word: "cat", hint_stage: 1)
      subscribe(state.room_id)

      next = info(state, {:hint_reveal, @game, 1, 2})

      assert next.hint_stage == 2
      assert next.seq == state.seq
      refute_received {:broadcast_action, _, _, _, _}
    end

    test "is ignored for another game or round, outside :drawing, or once past" do
      for {state, msg} <- [
            {drawing(), {:hint_reveal, "TEST-other-game", 1, 1}},
            {drawing(), {:hint_reveal, @game, 2, 1}},
            {drawing(phase: :round_end), {:hint_reveal, @game, 1, 1}},
            {drawing(phase: :choosing, current_word: nil), {:hint_reveal, @game, 1, 1}},
            {drawing(hint_stage: 2), {:hint_reveal, @game, 1, 1}}
          ] do
        subscribe(state.room_id)
        assert info(state, msg) == state
        refute_received {:broadcast_action, _, _, _, _}
      end
    end
  end

  describe "{:round_ended, ...} (time up)" do
    test "ends the current round once: one score, one result, one Time's up" do
      state = drawing(correct_guessers: [@guesser], round_guesser_points: [300])
      subscribe(state.room_id)

      ended = info(state, {:round_ended, @time_up})

      assert %{phase: :round_end, round_active: false, round_deadline: nil} = ended
      assert score(ended, @drawer) == 300
      assert length(ended.round_results) == 1
      assert times_up(ended) == 1
      assert_received {:broadcast_action, _, :room_delta, delta, _}
      assert %{phase: :round_end, round_remaining_ms: 0, revealed_word: "elephant"} = delta

      flush_broadcasts()
      assert info(ended, {:round_ended, @time_up}) == ended
      refute_received {:broadcast_action, _, _, _, _}
    end

    test "an expiry still queued when everyone guessed changes nothing" do
      {{:ok, {:correct, _}}, guessed} =
        call(drawing(), {:submit_message, @guesser, "elephant"})

      assert %{phase: :round_end, round_deadline: nil} = guessed
      assert length(guessed.round_results) == 1
      subscribe(guessed.room_id)

      assert info(guessed, {:round_ended, @time_up}) == guessed
      refute_received {:broadcast_action, _, _, _, _}
      assert times_up(guessed) == 0
    end

    test "an expiry for another round or game, or without them, changes nothing" do
      state = drawing()
      subscribe(state.room_id)

      for msg <- [
            %{@time_up | round: 2},
            %{@time_up | game_id: "TEST-other-game"},
            %{reason: :time_up}
          ] do
        assert info(state, {:round_ended, msg}) == state
      end

      assert info(drawing(game_id: nil), {:round_ended, %{@time_up | game_id: nil}}).phase ==
               :drawing

      refute_received {:broadcast_action, _, _, _, _}
    end
  end

  describe "a live :drawing phase" do
    setup do
      creator = create_user()
      player = create_user()
      room = start_room(creator)
      {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})

      {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: ["elephant"]})
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)

      %{room: room, creator: creator, game_id: started.game_id, pid: pid}
    end

    # Every :room_delta until the round-end one, with its arrival time.
    defp collect_deltas(acc \\ []) do
      receive do
        {:broadcast_action, _, :room_delta, delta, _} ->
          acc = [{System.monotonic_time(:millisecond), delta} | acc]
          if delta.phase == :round_end, do: Enum.reverse(acc), else: collect_deltas(acc)
      after
        5_000 -> flunk("no round-end delta; got #{length(acc)} deltas")
      end
    end

    test "with no activity: two hint deltas between the commit and the round end", ctx do
      # A 2 s round: reveals at 750 and 1_375 ms, time up at 2_000 ms.
      :sys.replace_state(ctx.pid, &%{&1 | round_duration: 2})
      subscribe(ctx.room.id)

      {:ok, _} = RoomServer.choose_word(ctx.room.id, ctx.creator.id, "elephant")

      assert [{commit_at, commit}, {s1_at, s1}, {s2_at, s2}, {end_at, ended}] = collect_deltas()

      assert commit.phase == :drawing
      assert commit.word_display == WordHints.hint_for_stage("elephant", 0)
      assert commit.round_remaining_ms in 1_500..2_000
      assert commit.round_duration == 2

      assert s1.word_display == WordHints.hint_for_stage("elephant", 1)
      assert s2.word_display == WordHints.hint_for_stage("elephant", 2)
      assert s1.phase == :drawing and s2.phase == :drawing
      # No second delta right after the commit (the old :timer_started one).
      assert s1_at - commit_at >= 600
      assert s2_at > s1_at

      assert %{revealed_word: "elephant", round_remaining_ms: 0} = ended
      assert end_at - commit_at >= 1_900

      # A late duplicate expiry is ignored.
      before = :sys.get_state(ctx.pid)
      send(ctx.pid, {:round_ended, %{game_id: ctx.game_id, round: 1, reason: :time_up}})
      assert :sys.get_state(ctx.pid) == before
      refute_receive {:broadcast_action, _, :room_delta, _, _}, 100
    end
  end
end
