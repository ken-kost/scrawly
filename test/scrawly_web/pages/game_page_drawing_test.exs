defmodule ScrawlyWeb.Pages.GamePageDrawingTest do
  @moduledoc """
  `:complete_stroke`, `:clear_drawing_cmd` and `:undo_drawing_cmd` act as the
  session user, who must be the current drawer while the room is `:drawing`.
  The room publishes every successful change to the whole room, sequenced
  (the sending tab included: it ignores its own echo); the commands broadcast
  nothing themselves. They are the drawer tab's op queue: every applied or
  duplicate op is acked with `:stroke_op_acked` and its `op_seq`, never with a
  seq.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.{RoomServer, StrokeRules}
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @instance "i-1"
  @stroke_id "s-1700000000000-1"
  @drawn %{path: "M 10 20 L 30 40", color: "#d63838", width: 5}
  # What the room stores for a :complete_stroke with the default params.
  @stroke Map.put(@drawn, :id, @stroke_id)
  @stroke2 %{id: "s-2", path: "M 1 1 L 2 2", color: "#000000", width: 2}
  @op %{op_epoch: "epoch-1", op_seq: 1}

  setup do
    creator = create_user()
    player = create_user()
    spectator = create_user()
    room = start_room(creator)

    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(player)).next_action.name ==
             :room_resynced

    assert GamePage.command(:join_as_watcher, %{room_id: room.id}, server_for(spectator)).next_action.name ==
             :room_resynced

    %{room: room, creator: creator, player: player, spectator: spectator}
  end

  defp tab(user), do: %{server_for(user) | instance_id: @instance}

  defp stroke_params(room, extra) do
    @drawn
    |> Map.merge(%{room_id: room.id, stroke_id: @stroke_id})
    |> Map.merge(extra)
  end

  defp numbered(stroke, n), do: %{stroke | id: "s-n#{n}"}

  defp run(command, room, server, extra \\ %{})

  defp run(:complete_stroke, room, server, extra),
    do: GamePage.command(:complete_stroke, stroke_params(room, extra), server)

  defp run(command, room, server, extra),
    do: GamePage.command(command, Map.merge(%{room_id: room.id}, extra), server)

  defp strokes(room), do: room_state!(room.id).drawing_strokes

  defp subscribe_room(room) do
    Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room.id}))
  end

  # The room's own broadcast of a change: sequenced, excluding nobody.
  defp assert_published(room, action, params) do
    room_id = room.id
    assert_receive {:broadcast_action, {:room, ^room_id}, ^action, received, []}
    assert is_integer(received.seq)
    assert Map.delete(received, :seq) == params
    received
  end

  defp refute_published, do: refute_receive({:broadcast_action, _, _, _, _}, 50)

  defp assert_denied(result, command, reason, extra \\ %{}) do
    assert result.next_action.name == :command_denied
    assert result.next_action.params == Map.merge(%{command: command, reason: reason}, extra)
    assert result.broadcasts == []
  end

  defp assert_acked(result, op_seq) do
    assert result.next_action.name == :stroke_op_acked
    assert result.next_action.params == %{op_seq: op_seq}
  end

  defp assert_rejected(result, reason, stored) do
    assert result.next_action.name == :stroke_rejected
    assert result.next_action.params.reason == reason
    assert result.next_action.params.strokes == stored
    assert result.broadcasts == []
  end

  defp outsiders(ctx) do
    [
      player: tab(ctx.player),
      spectator: tab(ctx.spectator),
      stranger: tab(create_user()),
      anon: %{anon_server("anon-#{System.unique_integer([:positive])}") | instance_id: @instance},
      empty: %Hologram.Server{}
    ]
  end

  describe "the drawer while :drawing" do
    setup ctx do
      start_drawing!(ctx.room, ctx.creator)
      subscribe_room(ctx.room)
      :ok
    end

    test ":complete_stroke stores the stroke; the room publishes it to every tab", ctx do
      seq = room_state!(ctx.room.id).seq
      result = run(:complete_stroke, ctx.room, tab(ctx.creator), @op)

      assert_acked(result, 1)
      assert result.broadcasts == []
      assert strokes(ctx.room) == [@stroke]

      published =
        assert_published(ctx.room, :stroke_completed, Map.put(@drawn, :stroke_id, @stroke_id))

      assert published.seq == seq + 1
    end

    test "only id, path, color and width are stored or published", ctx do
      extra = %{evil: "x", user_id: ctx.player.id, id: "forged-id"}
      run(:complete_stroke, ctx.room, tab(ctx.creator), extra)

      assert strokes(ctx.room) == [@stroke]
      assert_published(ctx.room, :stroke_completed, Map.put(@drawn, :stroke_id, @stroke_id))
    end

    test "a stroke without a sane stroke id is rejected", ctx do
      for id <- [nil, "", 7, String.duplicate("a", 65)] do
        result = run(:complete_stroke, ctx.room, tab(ctx.creator), %{stroke_id: id})
        assert_rejected(result, :invalid_stroke, [])
        assert result.next_action.params.stroke_id == nil
      end

      assert strokes(ctx.room) == []
    end

    test "every stroke command replies :stroke_op_acked with its op_seq", ctx do
      server = tab(ctx.creator)

      assert_acked(run(:complete_stroke, ctx.room, server, %{op_epoch: "e", op_seq: 1}), 1)

      assert_acked(
        run(:undo_drawing_cmd, ctx.room, server, %{
          stroke_id: @stroke_id,
          op_epoch: "e",
          op_seq: 2
        }),
        2
      )

      assert_acked(run(:clear_drawing_cmd, ctx.room, server, %{op_epoch: "e", op_seq: 3}), 3)

      # Without a (valid) pair the op is still applied and acked, unordered.
      assert_acked(run(:complete_stroke, ctx.room, server, %{op_seq: 4}), nil)
      assert_acked(run(:clear_drawing_cmd, ctx.room, server, %{op_epoch: "e", op_seq: "5"}), nil)
    end

    test "duplicates are acked and publish nothing", ctx do
      server = tab(ctx.creator)
      run(:complete_stroke, ctx.room, server, %{op_epoch: "e", op_seq: 1})
      assert_published(ctx.room, :stroke_completed, Map.put(@drawn, :stroke_id, @stroke_id))
      seq = room_state!(ctx.room.id).seq

      # The same op resent, then the same stroke id under a newer op.
      for op <- [%{op_epoch: "e", op_seq: 1}, %{op_epoch: "e", op_seq: 2}] do
        assert_acked(run(:complete_stroke, ctx.room, server, op), op.op_seq)
      end

      assert_acked(run(:clear_drawing_cmd, ctx.room, server, %{op_epoch: "e", op_seq: 1}), 1)
      assert_acked(run(:undo_drawing_cmd, ctx.room, server, %{stroke_id: "s-unknown"}), nil)

      refute_published()
      assert room_state!(ctx.room.id).seq == seq
      assert strokes(ctx.room) == [@stroke]
    end

    test ":undo_drawing_cmd removes the given stroke and broadcasts the rest", ctx do
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, @stroke)
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, @stroke2)

      result =
        run(:undo_drawing_cmd, ctx.room, tab(ctx.creator), Map.put(@op, :stroke_id, @stroke2.id))

      assert_acked(result, 1)
      assert result.broadcasts == []
      assert strokes(ctx.room) == [@stroke]

      assert_published(ctx.room, :stroke_completed, Map.put(@drawn, :stroke_id, @stroke_id))

      assert_published(
        ctx.room,
        :stroke_completed,
        Map.put(Map.delete(@stroke2, :id), :stroke_id, "s-2")
      )

      assert_published(ctx.room, :drawing_undone, %{strokes: [@stroke]})
    end

    test ":clear_drawing_cmd empties the canvas and broadcasts", ctx do
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, @stroke)

      result = run(:clear_drawing_cmd, ctx.room, tab(ctx.creator), @op)

      assert_acked(result, 1)
      assert result.broadcasts == []
      assert strokes(ctx.room) == []

      assert_published(ctx.room, :stroke_completed, Map.put(@drawn, :stroke_id, @stroke_id))
      assert_published(ctx.room, :drawing_cleared, %{})
    end

    test "a forged user_id param changes nothing for the drawer", ctx do
      forged = %{user_id: ctx.player.id, player_id: ctx.player.id}

      run(:complete_stroke, ctx.room, tab(ctx.creator), forged)
      assert strokes(ctx.room) == [@stroke]
      assert_published(ctx.room, :stroke_completed, Map.put(@drawn, :stroke_id, @stroke_id))

      run(:clear_drawing_cmd, ctx.room, tab(ctx.creator), forged)
      assert_published(ctx.room, :drawing_cleared, %{})
    end
  end

  describe "anyone but the drawer" do
    setup ctx do
      start_drawing!(ctx.room, ctx.creator)
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, @stroke)
      :ok
    end

    test "is denied every stroke command and changes nothing", ctx do
      before = room_state!(ctx.room.id)

      for {who, server} <- outsiders(ctx),
          {command, reason} <- [
            complete_stroke: :not_drawer,
            clear_drawing_cmd: :not_drawer,
            undo_drawing_cmd: :not_drawer
          ] do
        reason = if who in [:anon, :empty], do: :unauthenticated, else: reason
        assert_denied(run(command, ctx.room, server), command, reason)
      end

      # The remaining ms are computed when the state is read.
      transient = [:round_remaining_ms, :choice_remaining_ms]

      assert room_state!(ctx.room.id) |> Map.drop(transient) == Map.drop(before, transient)

      assert strokes(ctx.room) == [@stroke]
    end

    test "the denial carries the op_seq of the op", ctx do
      op = %{op_epoch: "e", op_seq: 7, stroke_id: @stroke_id}

      for command <- [:complete_stroke, :clear_drawing_cmd, :undo_drawing_cmd] do
        assert_denied(run(command, ctx.room, tab(ctx.player), op), command, :not_drawer, %{
          op_seq: 7
        })

        assert_denied(run(command, ctx.room, anon_server(), op), command, :unauthenticated, %{
          op_seq: 7
        })
      end

      assert strokes(ctx.room) == [@stroke]
    end

    test "cannot pass as the drawer with a forged user_id", ctx do
      forged = %{user_id: ctx.creator.id, player_id: ctx.creator.id, is_drawer: true}

      for command <- [:complete_stroke, :clear_drawing_cmd, :undo_drawing_cmd] do
        assert_denied(run(command, ctx.room, tab(ctx.player), forged), command, :not_drawer)

        assert_denied(
          run(command, ctx.room, anon_server(), forged),
          command,
          :unauthenticated
        )
      end

      assert strokes(ctx.room) == [@stroke]
    end
  end

  describe "the drawer outside :drawing" do
    test "is denied while choosing a word", ctx do
      {:ok, _started} =
        RoomServer.start_game(ctx.room.id, ctx.creator.id, %{word_choices: ["zz"]})

      assert room_state!(ctx.room.id).phase == :choosing

      for command <- [:complete_stroke, :clear_drawing_cmd, :undo_drawing_cmd] do
        assert_denied(run(command, ctx.room, tab(ctx.creator)), command, :wrong_phase)
      end

      assert strokes(ctx.room) == []
    end

    test "is denied after time is up", ctx do
      start_drawing!(ctx.room, ctx.creator)
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, @stroke)

      assert expire_round!(ctx.room).phase == :round_end

      for command <- [:complete_stroke, :clear_drawing_cmd, :undo_drawing_cmd] do
        assert_denied(run(command, ctx.room, tab(ctx.creator)), command, :wrong_phase)
      end

      assert strokes(ctx.room) == [@stroke]
    end

    test "gets :not_found once the room is gone", ctx do
      stop_room(ctx.room.id)
      assert_room_stopped(ctx.room.id)

      for command <- [:complete_stroke, :clear_drawing_cmd, :undo_drawing_cmd] do
        assert_denied(run(command, ctx.room, tab(ctx.creator)), command, :not_found)
      end
    end
  end

  describe "invalid strokes and limits" do
    setup ctx do
      start_drawing!(ctx.room, ctx.creator)
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, @stroke)
      :ok
    end

    test "are rejected with :stroke_rejected and nothing is stored", ctx do
      for bad <- [
            %{path: 42},
            %{path: ["M 1 2"]},
            %{path: nil},
            %{path: ""},
            %{path: "M 1 2\" onload=\"alert(1)"},
            %{path: String.duplicate("1", StrokeRules.max_path_bytes() + 1)},
            %{color: "red"},
            %{color: "#fff"},
            %{color: nil},
            %{width: 0},
            %{width: 41},
            %{width: 2.5},
            %{width: "5"}
          ] do
        result =
          run(:complete_stroke, ctx.room, tab(ctx.creator), Map.put(bad, :stroke_id, "s-bad"))

        assert_rejected(result, :invalid_stroke, [@stroke])
        assert result.next_action.params.stroke_id == "s-bad"
        assert result.next_action.params.op_seq == nil
      end

      assert strokes(ctx.room) == [@stroke]
    end

    test "the rejection carries the op_seq", ctx do
      bad = %{stroke_id: "s-bad", color: "red", op_epoch: "e", op_seq: 4}
      result = run(:complete_stroke, ctx.room, tab(ctx.creator), bad)

      assert_rejected(result, :invalid_stroke, [@stroke])
      assert result.next_action.params.op_seq == 4
    end

    test "stroke 501 is rejected", ctx do
      for n <- 2..StrokeRules.max_strokes(),
          do: :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, numbered(@stroke2, n))

      stored = strokes(ctx.room)
      assert length(stored) == 500

      result = run(:complete_stroke, ctx.room, tab(ctx.creator), %{stroke_id: "s-501"})
      assert_rejected(result, :stroke_limit, stored)
      assert strokes(ctx.room) == stored
    end

    test "a stroke that would push the canvas over the byte budget is rejected", ctx do
      big = %{@stroke | path: String.duplicate("1", 60_000)}

      # 60_000 * 33 + the first stroke's 15 bytes: a 33rd big stroke still fits,
      # a 34th would exceed 2_000_000 bytes.
      for n <- 1..33,
          do: :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, numbered(big, n))

      stored = strokes(ctx.room)

      result =
        run(:complete_stroke, ctx.room, tab(ctx.creator), %{path: big.path, stroke_id: "s-34"})

      assert_rejected(result, :stroke_limit, stored)
      assert strokes(ctx.room) == stored
    end
  end

  describe "client actions" do
    test ":send_stroke_op puts the op's command, with no user_id" do
      component = %Hologram.Component{
        props: %{room_id: "r1"},
        state: %{current_user_id: "forged"}
      }

      op = %{op_epoch: "e1", op_seq: 3}

      commit =
        GamePage.action(
          :send_stroke_op,
          Map.merge(op, %{
            kind: "commit",
            stroke_id: "s-1",
            path: "M 1 2",
            color: "#000000",
            width: 2,
            user_id: "forged"
          }),
          component
        )

      assert commit.next_command.name == :complete_stroke

      assert commit.next_command.params == %{
               room_id: "r1",
               op_epoch: "e1",
               op_seq: 3,
               stroke_id: "s-1",
               path: "M 1 2",
               color: "#000000",
               width: 2
             }

      undo =
        GamePage.action(
          :send_stroke_op,
          Map.merge(op, %{kind: "undo", stroke_id: "s-1"}),
          component
        )

      assert {undo.next_command.name, undo.next_command.params} ==
               {:undo_drawing_cmd, %{room_id: "r1", op_epoch: "e1", op_seq: 3, stroke_id: "s-1"}}

      clear = GamePage.action(:send_stroke_op, Map.put(op, :kind, "clear"), component)

      assert {clear.next_command.name, clear.next_command.params} ==
               {:clear_drawing_cmd, %{room_id: "r1", op_epoch: "e1", op_seq: 3}}

      assert GamePage.action(:send_stroke_op, Map.put(op, :kind, "evil"), component) == component
    end

    test ":clear_canvas empties the canvas and leaves the command to the op queue" do
      component = %Hologram.Component{
        props: %{room_id: "r1"},
        state: %{drawing_strokes: [@stroke]}
      }

      cleared = GamePage.action(:clear_canvas, %{}, component)
      assert cleared.state.drawing_strokes == []
      assert cleared.next_command == nil
    end

    test ":stroke_op_acked changes nothing; a stroke :command_denied only resyncs" do
      component = %Hologram.Component{
        props: %{room_id: "r1"},
        state: %{drawing_strokes: [@stroke], leaving?: false, resync_requested_at: nil}
      }

      assert GamePage.action(:stroke_op_acked, %{op_seq: 2}, component) == component

      denied =
        GamePage.action(
          :command_denied,
          %{command: :complete_stroke, reason: :wrong_phase, op_seq: 2},
          component
        )

      assert Map.delete(denied.state, :resync_requested_at) ==
               Map.delete(component.state, :resync_requested_at)

      assert denied.next_command.name == :resync_room
      assert denied.next_action == nil
    end

    test ":stroke_rejected replaces the drawer's strokes with the stored ones" do
      component = %Hologram.Component{state: %{drawing_strokes: [@stroke, @stroke2]}}

      result =
        GamePage.action(
          :stroke_rejected,
          %{stroke_id: "s-2", reason: :invalid_stroke, strokes: [@stroke], op_seq: 2},
          component
        )

      assert result.state.drawing_strokes == [@stroke]
    end
  end
end
