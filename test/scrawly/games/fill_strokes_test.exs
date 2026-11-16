defmodule Scrawly.Games.FillStrokesTest do
  @moduledoc """
  Fills (#43) travel every path a stroke does, their flag with them: the
  drawer's op (`:send_stroke_op` -> `:complete_stroke`), the room
  (`StrokeRules` checks, storage, the `:stroke_completed` broadcast, the
  views and snapshots, undo, a rejection's canvas, the rate limit), a
  viewer's page and canvas, the round replay saved in the Game's JSONB
  `round_details` and the score page that renders it. Strokes stored
  before fills existed (no flag) still load and render as lines.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.JsCallTrace, only: [js_calls: 1]

  alias Hologram.Template.Renderer
  alias Scrawly.Games
  alias Scrawly.Games.{RoomServer, StrokeRules}
  alias ScrawlyWeb.Components.DrawingCanvas
  alias ScrawlyWeb.Pages.{GamePage, GameScorePage}

  @moduletag :capture_log

  @square "M 101 101 L 299 101 L 299 299 L 101 299 Z M 150 150 L 150 160 L 160 160 L 160 150 Z"
  # As stored: width 1, `fill: true`.
  @fill %{id: "s-fill-1", path: @square, color: "#2563eb", width: 1, fill: true}
  @line %{id: "s-line-1", path: "M 10 20 L 30 40", color: "#d63838", width: 5}

  setup do
    creator = create_user()
    player = create_user()
    room = start_room(creator)
    {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})
    start_drawing!(room, creator)
    %{room: room, creator: creator, player: player}
  end

  defp tab(user), do: %{server_for(user) | instance_id: "i-1"}

  defp commit(ctx, stroke, op_seq, extra \\ %{}) do
    params =
      %{
        room_id: ctx.room.id,
        op_epoch: "epoch-1",
        op_seq: op_seq,
        stroke_id: stroke.id,
        path: stroke.path,
        color: stroke.color,
        width: stroke.width
      }
      |> Map.merge(if StrokeRules.fill?(stroke), do: %{fill: true}, else: %{})
      |> Map.merge(extra)

    GamePage.command(:complete_stroke, params, tab(ctx.creator))
  end

  defp subscribe_room(room),
    do:
      Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room.id}))

  defp strokes(room), do: room_state!(room.id).drawing_strokes

  defp render(module, vars),
    do:
      module.template().(vars)
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})
      |> elem(0)

  describe "the room" do
    test "stores a fill with its flag and publishes it; a line goes out as it always did", ctx do
      subscribe_room(ctx.room)
      room_id = ctx.room.id

      # Whatever width the client sent, the room stores 1.
      assert commit(ctx, %{@fill | width: 17}, 1).next_action.name == :stroke_op_acked
      assert commit(ctx, @line, 2).next_action.name == :stroke_op_acked

      assert strokes(ctx.room) == [@fill, @line]

      assert_receive {:broadcast_action, {:room, ^room_id}, :stroke_completed, fill, []}

      assert Map.delete(fill, :seq) == %{
               stroke_id: "s-fill-1",
               path: @square,
               color: "#2563eb",
               width: 1,
               fill: true
             }

      assert_receive {:broadcast_action, {:room, ^room_id}, :stroke_completed, line, []}

      assert Map.delete(line, :seq) == %{
               stroke_id: "s-line-1",
               path: @line.path,
               color: "#d63838",
               width: 5
             }
    end

    test "a resync's snapshot carries the fill", ctx do
      commit(ctx, @fill, 1)
      result = GamePage.command(:resync_room, %{room_id: ctx.room.id}, tab(ctx.player))
      assert result.next_action.name == :room_resynced
      assert result.next_action.params.drawing_strokes == [@fill]
    end

    test "an invalid fill is rejected with the canvas as stored, fills flagged", ctx do
      commit(ctx, @fill, 1)

      for {extra, n} <- [
            {%{path: "M 1 2 Q 3 4 5 6 Z"}, 2},
            {%{path: "m 1 2 l 3 4 z"}, 3},
            {%{path: String.duplicate("1", 8_001)}, 4},
            {%{color: "blue"}, 5},
            {%{fill: "true"}, 6},
            {%{fill: 1}, 7}
          ] do
        result = commit(ctx, %{@fill | id: "s-bad-#{n}"}, n, extra)
        assert result.next_action.name == :stroke_rejected, inspect(extra)
        assert result.next_action.params.reason == :invalid_stroke
        assert result.next_action.params.strokes == [@fill]
      end

      assert strokes(ctx.room) == [@fill]
    end

    test "one undo op takes a fill back; only its id goes out", ctx do
      commit(ctx, @line, 1)
      commit(ctx, @fill, 2)
      subscribe_room(ctx.room)
      room_id = ctx.room.id

      result =
        GamePage.command(
          :undo_drawing_cmd,
          %{room_id: room_id, op_epoch: "epoch-1", op_seq: 3, stroke_id: @fill.id},
          tab(ctx.creator)
        )

      assert result.next_action.name == :stroke_op_acked
      assert_receive {:broadcast_action, {:room, ^room_id}, :drawing_undone, params, []}
      assert Map.delete(params, :seq) == %{stroke_id: @fill.id}
      assert strokes(ctx.room) == [@line]
    end

    test "fills count against the op rate limit like any stroke", ctx do
      {ops, _window} = StrokeRules.op_rate_limit()

      for n <- 1..ops do
        assert commit(ctx, %{@fill | id: "s-f#{n}"}, n).next_action.name == :stroke_op_acked
      end

      # Over the limit: no reply, nothing stored.
      assert commit(ctx, %{@fill | id: "s-over"}, ops + 1).next_action == nil
      assert length(strokes(ctx.room)) == ops
    end
  end

  describe "the replay and the score page" do
    test "a round's fill is kept in the replay, saved in JSONB, read back and rendered", ctx do
      commit(ctx, @line, 1)
      commit(ctx, @fill, 2)
      expire_round!(ctx.room)

      [pid] = for {pid, _} <- Registry.lookup(Scrawly.RoomRegistry, ctx.room.id), do: pid
      [result] = :sys.get_state(pid).round_results

      assert result.drawing_strokes == [
               %{path: @line.path, color: "#d63838", width: 5},
               %{path: @square, color: "#2563eb", width: 1, fill: true}
             ]

      # The Game's round_details, as the room saves them at the game's end,
      # plus a round saved before fills (no flag) for the same page.
      game_id = room_state!(ctx.room.id).game_id
      {:ok, game} = Games.get_game_by_id(game_id)

      legacy = %{
        "round" => 2,
        "word" => "TESTold",
        "drawer_name" => "x",
        "drawing_strokes" => [
          %{"id" => "s-old", "path" => "M 5 5 L 50 50", "color" => "#0a0a0a", "width" => 4}
        ]
      }

      {:ok, _} = Games.save_round_details(game, [result, legacy])
      {:ok, reread} = Games.get_game_by_id(game_id)

      # JSONB: string keys, the flag a JSON true.
      [saved, old] = reread.round_details
      assert Enum.at(saved["drawing_strokes"], 1)["fill"] == true
      refute Map.has_key?(hd(saved["drawing_strokes"]), "fill")
      refute Map.has_key?(hd(old["drawing_strokes"]), "fill")

      {component, _server} =
        GameScorePage.init(%{game_id: game_id}, %Hologram.Component{}, server_for(ctx.creator))

      [round1, round2] = component.state.round_details

      assert Enum.at(round1.drawing_strokes, 1) == %{
               path: @square,
               color: "#2563eb",
               width: 1,
               fill: true
             }

      assert round2.drawing_strokes == [%{path: "M 5 5 L 50 50", color: "#0a0a0a", width: 4}]

      # The thumbnails, and the enlarged drawing of round 1.
      for state <- [component.state, %{component.state | modal_round: 1}] do
        html = render(GameScorePage, Map.put(state, :game_id, game_id))

        assert html =~
                 ~s(<path d="#{@square}" fill="#2563eb" fill-rule="evenodd" stroke="none"></path>)

        assert html =~
                 ~s(<path d="M 10 20 L 30 40" stroke="#d63838" stroke-width="5" fill="none" stroke-linecap="round" stroke-linejoin="round"></path>)

        # The game saved before fills renders as it always did.
        assert html =~
                 ~s(<path d="M 5 5 L 50 50" stroke="#0a0a0a" stroke-width="4" fill="none" stroke-linecap="round" stroke-linejoin="round"></path>)
      end

      html =
        render(GameScorePage, Map.merge(component.state, %{game_id: game_id, modal_round: 1}))

      # Two thumbnails' fill and the modal's.
      assert length(String.split(html, ~s(fill-rule="evenodd"))) - 1 == 2
    end
  end

  describe "pages" do
    test "a viewer's page hands a pushed fill to its canvas with its flag" do
      component = %Hologram.Component{
        props: %{room_id: "r1"},
        state: %{
          is_drawer: false,
          last_seq: 1,
          resync_requested_at: nil,
          resync_owed_seq: nil,
          leaving?: false
        }
      }

      params = %{
        stroke_id: @fill.id,
        path: @square,
        color: "#2563eb",
        width: 1,
        fill: true,
        seq: 2
      }

      # drawing_manager.mjs draws a viewer's strokes (its inside, evenodd, for
      # a fill: test/js/viewer_canvas.test.mjs); the page keeps none.
      {result, calls} = js_calls(fn -> GamePage.action(:stroke_completed, params, component) end)

      assert calls == [
               applyViewerStroke: [
                 %{id: @fill.id, path: @square, color: "#2563eb", width: 1, fill: true},
                 2
               ]
             ]

      line = %{stroke_id: "s-l", path: "M 1 1 L 2 2", color: "#000000", width: 3, seq: 3}
      {_result, calls} = js_calls(fn -> GamePage.action(:stroke_completed, line, result) end)

      assert calls == [
               applyViewerStroke: [
                 %{id: "s-l", path: "M 1 1 L 2 2", color: "#000000", width: 3, fill: false},
                 3
               ]
             ]

      # Hologram renders no stroke at all: the canvas's groups are empty.
      html = render(DrawingCanvas, %{is_drawer: false})
      assert html =~ ~s(<g id="game-canvas-strokes"></g>)
      refute html =~ "data-stroke-id"
    end

    test "the drawer's other tab adopts a fill as a fill" do
      component = %Hologram.Component{
        props: %{room_id: "r1"},
        state: %{
          is_drawer: true,
          drawing_strokes: [],
          last_seq: 1,
          strokes_seq: 1,
          resync_requested_at: nil,
          resync_owed_seq: nil,
          leaving?: false
        }
      }

      params = %{
        stroke_id: @fill.id,
        path: @square,
        color: "#2563eb",
        width: 1,
        fill: true,
        seq: 2
      }

      {_result, calls} = js_calls(fn -> GamePage.action(:stroke_completed, params, component) end)

      assert {:adoptStroke,
              [%{id: "s-fill-1", path: @square, color: "#2563eb", width: 1, fill: true}]} in calls
    end

    test ":send_stroke_op sends a fill's flag, and none for a line" do
      component = %Hologram.Component{props: %{room_id: "r1"}, state: %{game_id: "g1", round: 2}}

      op = %{
        op_epoch: "e1",
        op_seq: 3,
        kind: "commit",
        stroke_id: "s-1",
        path: @square,
        color: "#2563eb",
        width: 1
      }

      fill = GamePage.action(:send_stroke_op, Map.put(op, :fill, true), component)
      assert fill.next_command.name == :complete_stroke
      assert fill.next_command.params.fill == true

      for line_op <- [op, Map.put(op, :fill, false), Map.put(op, :fill, "true")] do
        line = GamePage.action(:send_stroke_op, line_op, component)
        refute Map.has_key?(line.next_command.params, :fill)
      end
    end
  end
end
