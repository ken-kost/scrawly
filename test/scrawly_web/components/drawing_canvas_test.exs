defmodule ScrawlyWeb.Components.DrawingCanvasTest do
  @moduledoc """
  Tests for drawing actions on GamePage including tool selection,
  multi-stroke state, undo, the canvas lifecycle (`:mounted`), the rule that
  turns the native stroke engine on and off (`GamePage.can_draw?/1`,
  `setDrawingEnabled`) and the round resets. Stroke broadcasts are sequenced
  like every `{:room}` action (see game_page_test.exs for the gap rule).
  Pointer input itself is native JS (stroke_engine.mjs; its geometry is
  tested in test/js/).
  """
  # js_calls/1 traces Hologram.JS.call/4 globally.
  use ExUnit.Case, async: false

  import Scrawly.JsCallTrace, only: [js_calls: 1, js_call_names: 1]

  alias ScrawlyWeb.Pages.GamePage

  defp drawing_component(overrides) do
    defaults = %{
      drawing_strokes: [],
      draw_tool: ScrawlyWeb.Components.DrawingToolbar.default_tool(),
      is_drawer: true,
      game_started: true,
      phase: :drawing,
      time_left: 60,
      current_user_id: "test-user",
      players: [],
      watchers: [],
      leaving?: false,
      last_seq: 1,
      strokes_seq: 1,
      resync_requested_at: nil,
      resync_owed_seq: nil,
      phase_entered_at: nil,
      zero_since: nil,
      tick_gen: 1,
      last_tick_at: nil,
      round_deadline_local: nil,
      choice_deadline_local: nil,
      choice_time_left: 0,
      choice_duration: 15,
      round_duration: 60,
      socket_token: "",
      room_code: "ABCD",
      channel_connected: false,
      channel_connecting: false,
      mount_id: 42
    }

    %Hologram.Component{props: %{room_id: "test-room"}, state: Map.merge(defaults, overrides)}
  end

  @s1 %{id: "s-1", path: "M 1 2", color: "#000000", width: 2}

  defp enabled_calls(calls), do: for({:setDrawingEnabled, [on]} <- calls, do: on)
  @s2 %{id: "s-2", path: "M 3 4 L 5 6", color: "#d63838", width: 5}

  # The full page state of a viewer (user-1) in round 1 of game g1, :drawing.
  defp page_component(overrides) do
    players = [
      %{id: "user-1", username: "You", score: 0},
      %{id: "user-2", username: "D", score: 0}
    ]

    state = %{
      room_code: "ABCD",
      socket_token: "",
      channel_connected: false,
      current_user_id: "user-1",
      players: players,
      max_players: 4,
      watchers: [],
      past_games: [],
      chat_messages: [],
      correct_guessers: [],
      is_creator: false,
      can_start_game: false,
      leaving?: false,
      room_status: :playing,
      last_seq: 4,
      delta_seq: 4,
      strokes_seq: 4,
      pending_private: nil,
      resync_requested_at: nil,
      resync_owed_seq: nil,
      stuck_seq: nil,
      phase_entered_at: nil,
      zero_since: nil,
      restoring?: false,
      channel_connecting: false,
      game_id: "g1",
      game_started: true,
      round: 1,
      total_rounds: 2,
      phase: :drawing,
      time_left: 50,
      choice_time_left: 0,
      choice_duration: 15,
      round_duration: 60,
      round_deadline_local: nil,
      choice_deadline_local: nil,
      tick_gen: 1,
      last_tick_at: nil,
      current_drawer: %{id: "user-2", username: "D"},
      current_word: nil,
      current_word_display: "_ _ _",
      word_length: 3,
      revealed_word: nil,
      word_choices: [],
      is_drawer: false,
      drawing_strokes: [@s1, @s2]
    }

    %Hologram.Component{props: %{room_id: "r1"}, state: Map.merge(state, overrides)}
  end

  # A :room_resynced snapshot for user-1 at seq 5 (a :room_delta carries the
  # same keys but chat, strokes and the viewer's own).
  defp refreshed(overrides) do
    Map.merge(
      %{
        room_id: "r1",
        status: :playing,
        players: [
          %{id: "user-1", username: "You", score: 0},
          %{id: "user-2", username: "D", score: 0}
        ],
        max_players: 4,
        watchers: [],
        past_games: [],
        chat_messages: [],
        correct_guessers: [],
        seq: 5,
        game_id: "g1",
        last_game_id: nil,
        current_round: 1,
        total_rounds: 2,
        current_drawer_id: "user-2",
        drawer_name: "D",
        phase: :drawing,
        round_remaining_ms: 45_000,
        choice_remaining_ms: 0,
        round_duration: 60,
        choice_duration: 15,
        word_display: "_ _ _",
        word_length: 3,
        revealed_word: nil,
        current_word: nil,
        word_choices: [],
        is_drawer: false,
        drawing_strokes: []
      },
      overrides
    )
  end

  describe "can_draw?/1" do
    test "only the drawer, only in :drawing" do
      assert GamePage.can_draw?(%{is_drawer: true, phase: :drawing})
      refute GamePage.can_draw?(%{is_drawer: false, phase: :drawing})
      refute GamePage.can_draw?(%{is_drawer: nil, phase: :drawing})
      refute GamePage.can_draw?(%{})
    end

    # The room ends the phase; the local countdown only clamps at 0.
    test "follows the phase, never the local countdown" do
      for phase <- [:idle, :choosing, :round_end] do
        refute GamePage.can_draw?(%{is_drawer: true, phase: phase, time_left: 30})
      end

      assert GamePage.can_draw?(%{is_drawer: true, phase: :drawing, time_left: 0})
    end
  end

  describe "native pointer input" do
    test "the canvases have no Hologram pointer bindings and the pages no pointer actions" do
      for file <- [
            "lib/scrawly_web/components/drawing_canvas.ex",
            "lib/scrawly_web/components/game_demo.ex"
          ] do
        refute File.read!(file) =~ "$pointer", file
      end

      for file <- ["lib/scrawly_web/pages/game_page.ex", "lib/scrawly_web/pages/home_page.ex"] do
        source = File.read!(file)
        refute source =~ "canvas_pointer_", file
        refute source =~ "demo_pointer_", file
        refute source =~ ":drawing?", file
      end
    end
  end

  describe "clear_canvas" do
    test "resets strokes to empty" do
      strokes = [%{id: "s-1", path: "M 100 150 L 120 160", color: "#000000", width: 2}]
      comp = drawing_component(%{drawing_strokes: strokes})

      result = GamePage.action(:clear_canvas, %{}, comp)

      assert result.state.drawing_strokes == []
    end
  end

  describe "stroke_completed" do
    test "appends completed stroke to non-drawer's strokes" do
      comp = drawing_component(%{is_drawer: false})
      params = %{stroke_id: "s1", path: "M 10 20 L 30 40", color: "#EF4444", width: 5, seq: 2}

      result = GamePage.action(:stroke_completed, params, comp)

      # The stroke keeps the seq it arrived with.
      assert result.state.drawing_strokes == [
               %{id: "s1", path: "M 10 20 L 30 40", color: "#EF4444", width: 5, seq: 2}
             ]

      assert result.state.last_seq == 2
    end

    test "ignores a stroke id the viewer already has" do
      comp = drawing_component(%{is_drawer: false, drawing_strokes: [@s1]})
      params = %{stroke_id: "s-1", path: "M 9 9", color: "#000000", width: 2, seq: 2}

      result = GamePage.action(:stroke_completed, params, comp)

      assert result.state.drawing_strokes == [@s1]
    end

    test "the drawer ignores its own echo but takes the seq" do
      comp = drawing_component(%{is_drawer: true})
      params = %{stroke_id: "s1", path: "M 10 20", color: "#000000", width: 2, seq: 2}

      result = GamePage.action(:stroke_completed, params, comp)

      assert result.state.drawing_strokes == []
      assert result.state.last_seq == 2
    end

    test "accumulates multiple strokes" do
      comp =
        drawing_component(%{
          is_drawer: false,
          drawing_strokes: [@s1]
        })

      params = %{stroke_id: "s2", path: "M 10 20", color: "#3B82F6", width: 10, seq: 2}

      result = GamePage.action(:stroke_completed, params, comp)

      assert length(result.state.drawing_strokes) == 2
    end
  end

  describe "drawing_cleared" do
    test "clears a viewer's strokes" do
      comp = drawing_component(%{is_drawer: false, drawing_strokes: [@s1]})

      {result, names} =
        js_call_names(fn -> GamePage.action(:drawing_cleared, %{seq: 2}, comp) end)

      assert result.state.drawing_strokes == []
      assert result.state.strokes_seq == 2
      # The live overlays go, their ids stay open (a stroke started after the
      # clear comes back with its next chunk).
      assert names == [:clearRemoteStrokes]
    end

    test "on the drawer's tab, only a clear from another tab touches the canvas" do
      comp = drawing_component(%{is_drawer: true, drawing_strokes: [@s1]})

      {result, calls} =
        js_calls(fn ->
          GamePage.action(:drawing_cleared, %{seq: 2, op_epoch: "epoch-a"}, comp)
        end)

      assert result.state.drawing_strokes == [@s1]
      assert result.state.last_seq == 2
      # drawing_manager.mjs compares the epoch with its own (applyRoomClear).
      assert calls == [applyRoomClear: ["epoch-a"]]
    end
  end

  describe "drawing_undone" do
    test "removes the stroke by id for a viewer; the drawer only takes the seq" do
      viewer = drawing_component(%{is_drawer: false, drawing_strokes: [@s1, @s2]})
      result = GamePage.action(:drawing_undone, %{stroke_id: @s2.id, seq: 2}, viewer)
      assert result.state.drawing_strokes == [@s1]

      drawer = drawing_component(%{drawing_strokes: [@s1, @s2]})

      {result, names} =
        js_call_names(fn ->
          GamePage.action(:drawing_undone, %{stroke_id: @s2.id, seq: 2}, drawer)
        end)

      assert result.state.drawing_strokes == [@s1, @s2]
      assert result.state.last_seq == 2
      # Its own undo already removed it; another tab's is removed here.
      assert names == [:forgetStroke]
    end
  end

  describe ":mounted" do
    test "sends the join init chose, and no poll" do
      comp = drawing_component(%{round_remaining_ms: 0, choice_remaining_ms: 0})

      assert GamePage.action(:mounted, %{join: nil}, comp).next_command == nil

      for {join, command} <- [player: :join_room, watcher: :join_as_watcher] do
        result = GamePage.action(:mounted, %{join: join}, comp)
        assert result.next_command.name == command
      end
    end

    test "restores the drawer's strokes and connects a member's game socket" do
      member = [%{id: "test-user", username: "T", score: 0}]

      comp =
        drawing_component(%{
          drawing_strokes: [@s1],
          players: member,
          socket_token: "tok",
          round_remaining_ms: 0,
          choice_remaining_ms: 0
        })

      {result, calls} = js_calls(fn -> GamePage.action(:mounted, %{join: nil}, comp) end)

      assert [
               {:mountCanvas, [42]},
               {:noteRoomChannel, ["test-room"]},
               {:setDrawTool, [%{tool: "brush", color: "#0a0a0a", size: 4}]},
               # The browser's saved colours (color_picker.mjs).
               {:savedColors, []},
               {:restoreStrokes, [[@s1]]},
               {:setDrawingEnabled, [true]},
               {:connectGameChannel, ["tok", "ABCD"]}
             ] =
               calls

      assert result.state.channel_connecting == true

      # Not a member yet: the join reply connects it (GameChannel refuses
      # non-members).
      outsider = %{comp | state: %{comp.state | players: []}}

      {_result, names} =
        js_call_names(fn -> GamePage.action(:mounted, %{join: :player}, outsider) end)

      refute :connectGameChannel in names
    end

    test "anchors init's countdowns and starts the tick chain, for the drawer or a viewer" do
      countdown_keys = [
        :round_deadline_local,
        :choice_deadline_local,
        :time_left,
        :choice_time_left,
        :choice_duration,
        :round_duration,
        :zero_since,
        :phase_entered_at,
        :tick_gen,
        :last_tick_at
      ]

      for is_drawer <- [true, false] do
        comp =
          drawing_component(%{
            is_drawer: is_drawer,
            drawing_strokes: [@s1],
            round_remaining_ms: 41_500,
            choice_remaining_ms: 0,
            choice_duration: 15,
            round_duration: 60
          })

        before = System.monotonic_time(:millisecond)
        result = GamePage.action(:mounted, %{join: nil}, comp)

        assert Map.drop(result.state, countdown_keys) == Map.drop(comp.state, countdown_keys)
        assert (result.state.round_deadline_local - before) in 41_500..42_000
        assert result.state.choice_deadline_local == nil
        assert result.state.time_left == 42
        assert result.state.choice_time_left == 0
        # The next_action slot is free: the chain starts here.
        assert result.next_action.name == :countdown_tick
      end
    end
  end

  describe ":room_resynced gives a viewer the room's strokes" do
    test "snapshots carry the real strokes, with or without the channel" do
      longer = [@s1, @s2, %{@s2 | id: "s-3"}]

      for connected <- [false, true], strokes <- [longer, [@s1]] do
        comp = page_component(%{channel_connected: connected})

        {result, calls} =
          js_calls(fn ->
            GamePage.action(:room_resynced, refreshed(%{drawing_strokes: strokes}), comp)
          end)

        assert result.state.drawing_strokes == strokes
        # Overlays of strokes the snapshot holds go; a stroke still being
        # drawn keeps its live preview.
        assert {:settleRemoteStrokes, [Enum.map(strokes, & &1.id)]} in calls
      end
    end

    test "a late joiner's canvas is not wiped by a delta" do
      comp = page_component(%{})
      delta = refreshed(%{}) |> Map.drop([:drawing_strokes, :chat_messages]) |> Map.put(:seq, 5)
      result = GamePage.action(:room_delta, delta, comp)
      assert result.state.drawing_strokes == [@s1, @s2]
    end
  end

  # setDrawingEnabled follows can_draw?/1 and is only called when it changes;
  # turning the engine off drops a stroke in progress without committing it.
  describe "round transitions turn the stroke engine on and off" do
    test "game start leaves a viewer's engine off; the drawer's turns on with :drawing" do
      lobby = page_component(%{game_started: false, game_id: nil, round: 0, phase: :idle})

      {started, calls} =
        js_calls(fn -> GamePage.action(:room_delta, refreshed(%{phase: :choosing}), lobby) end)

      assert started.state.game_started == true
      assert enabled_calls(calls) == []

      choosing = page_component(%{is_drawer: true, phase: :choosing})
      mine = %{current_drawer_id: "user-1"}

      {drawing, calls} =
        js_calls(fn -> GamePage.action(:room_delta, refreshed(mine), choosing) end)

      assert drawing.state.phase == :drawing
      assert enabled_calls(calls) == [true]
    end

    test "a new round and the game's end turn the drawer's engine off and reset the canvas" do
      in_round =
        page_component(%{
          is_drawer: true,
          current_drawer: %{id: "user-1", username: "You"},
          color_panel: true
        })

      {next_round, calls} =
        js_calls(fn ->
          GamePage.action(
            :room_delta,
            refreshed(%{current_round: 2, phase: :choosing, current_drawer_id: "user-1"}),
            in_round
          )
        end)

      assert next_round.state.round == 2
      assert next_round.state.drawing_strokes == []
      assert {:setDrawingPath, [""]} in calls
      assert enabled_calls(calls) == [false]
      # The colour panel closes with the drawing: the next turn's toolbar
      # starts closed.
      assert next_round.state.color_panel == false

      {ended, calls} =
        js_calls(fn ->
          GamePage.action(
            :room_delta,
            refreshed(%{status: :lobby, game_id: nil, current_round: 0, phase: :idle}),
            in_round
          )
        end)

      assert ended.state.game_started == false
      assert ended.state.drawing_strokes == []
      assert enabled_calls(calls) == [false]
      assert ended.state.color_panel == false
    end

    test "leaving :drawing turns it off and keeps the strokes" do
      comp = page_component(%{is_drawer: true, current_drawer: %{id: "user-1", username: "You"}})

      {result, calls} =
        js_calls(fn ->
          GamePage.action(
            :room_delta,
            refreshed(%{
              phase: :round_end,
              current_drawer_id: "user-1",
              round_remaining_ms: 0,
              revealed_word: "abc"
            }),
            comp
          )
        end)

      assert result.state.phase == :round_end
      assert result.state.drawing_strokes == [@s1, @s2]
      assert {:endDrawingPhase, []} in calls
      assert enabled_calls(calls) == [false]
    end

    test "a delta within :drawing leaves the engine alone" do
      comp = page_component(%{is_drawer: true, current_drawer: %{id: "user-1", username: "You"}})

      {result, calls} =
        js_calls(fn ->
          GamePage.action(
            :room_delta,
            refreshed(%{current_drawer_id: "user-1", round_remaining_ms: 30_000}),
            comp
          )
        end)

      assert GamePage.can_draw?(result.state)
      assert result.state.time_left == 30
      assert enabled_calls(calls) == []
    end

    test "a Back/Forward restore sets the engine for the restored page" do
      comp =
        page_component(%{
          is_drawer: true,
          current_drawer: %{id: "user-1", username: "You"},
          restoring?: true
        })

      {_result, calls} =
        js_calls(fn ->
          GamePage.action(
            :room_resynced,
            refreshed(%{current_drawer_id: "user-1", is_drawer: true, drawing_strokes: [@s1]}),
            comp
          )
        end)

      assert {:rebaseCanvas, [[@s1]]} in calls
      assert enabled_calls(calls) == [true]
    end
  end

  describe "tool selection actions" do
    @eraser %{tool: :eraser, color: "#0a0a0a", size: 2}

    test "select_color picks the brush in that colour, and pushes the tool" do
      comp = drawing_component(%{draw_tool: @eraser})

      {result, calls} =
        js_calls(fn -> GamePage.action(:select_color, %{color: "#d63838"}, comp) end)

      assert result.state.draw_tool == %{tool: :brush, color: "#d63838", size: 2}
      assert calls == [{:setDrawTool, [%{tool: "brush", color: "#d63838", size: 2}]}]
    end

    test "select_size sets the size and keeps the tool (the eraser too), and pushes it" do
      comp = drawing_component(%{draw_tool: @eraser})

      {result, calls} = js_calls(fn -> GamePage.action(:select_size, %{size: 10}, comp) end)

      assert result.state.draw_tool == %{tool: :eraser, color: "#0a0a0a", size: 10}
      assert calls == [{:setDrawTool, [%{tool: "eraser", color: "#0a0a0a", size: 10}]}]

      brush = drawing_component(%{draw_tool: %{@eraser | tool: :brush}})
      assert GamePage.action(:select_size, %{size: 30}, brush).state.draw_tool.tool == :brush
    end

    test "select_size takes the slider's value (its throttled $change), clamped to 1..40" do
      comp = drawing_component(%{draw_tool: @eraser})

      {result, calls} =
        js_calls(fn -> GamePage.action(:select_size, %{event: %{value: "37"}}, comp) end)

      assert result.state.draw_tool == %{tool: :eraser, color: "#0a0a0a", size: 37}
      assert calls == [{:setDrawTool, [%{tool: "eraser", color: "#0a0a0a", size: 37}]}]

      for {value, size} <- [{"0", 1}, {"99", 40}, {"x", 2}, {"4.5", 2}, {"", 2}] do
        result = GamePage.action(:select_size, %{event: %{value: value}}, comp)
        assert result.state.draw_tool.size == size, inspect(value)
      end
    end

    test "toggle_eraser turns the eraser on, and off again with the brush as it was" do
      comp = drawing_component(%{draw_tool: %{tool: :brush, color: "#2a6df4", size: 5}})

      {on, calls} = js_calls(fn -> GamePage.action(:toggle_eraser, %{}, comp) end)

      assert on.state.draw_tool == %{tool: :eraser, color: "#2a6df4", size: 5}
      assert calls == [{:setDrawTool, [%{tool: "eraser", color: "#2a6df4", size: 5}]}]

      off = GamePage.action(:toggle_eraser, %{}, on)
      assert off.state.draw_tool == comp.state.draw_tool
    end

    test "a page state without a tool starts from the default one" do
      comp = drawing_component(%{}) |> Map.update!(:state, &Map.delete(&1, :draw_tool))

      assert GamePage.action(:toggle_eraser, %{}, comp).state.draw_tool ==
               %{ScrawlyWeb.Components.DrawingToolbar.default_tool() | tool: :eraser}
    end
  end
end
