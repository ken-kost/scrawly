defmodule ScrawlyWeb.Components.DrawingCanvasTest do
  @moduledoc """
  Tests for drawing actions on GamePage including tool selection,
  multi-stroke state, and undo.
  """
  use ExUnit.Case, async: true

  alias ScrawlyWeb.Pages.GamePage

  defp drawing_component(overrides \\ %{}) do
    defaults = %{
      drawing_strokes: [],
      drawing?: false,
      draw_color: "#000000",
      draw_width: 2,
      draw_eraser: false,
      is_drawer: true,
      game_started: true,
      time_left: 60,
      room_id: "test-room"
    }

    %Hologram.Component{state: Map.merge(defaults, overrides)}
  end

  describe "canvas_pointer_down" do
    test "starts drawing for drawer" do
      comp = drawing_component()
      params = %{event: %{offset_x: 100, offset_y: 150}}

      result = GamePage.action(:canvas_pointer_down, params, comp)

      assert result.state.drawing? == true
    end

    test "does nothing for non-drawer" do
      comp = drawing_component(%{is_drawer: false})
      params = %{event: %{offset_x: 100, offset_y: 150}}

      result = GamePage.action(:canvas_pointer_down, params, comp)

      assert result.state.drawing? == false
    end

    test "does nothing when time is 0" do
      comp = drawing_component(%{time_left: 0})
      params = %{event: %{offset_x: 100, offset_y: 150}}

      result = GamePage.action(:canvas_pointer_down, params, comp)

      assert result.state.drawing? == false
    end
  end

  describe "canvas_pointer_move" do
    test "does not update Hologram state (drawing managed by JS)" do
      comp = drawing_component(%{drawing?: true})
      params = %{event: %{offset_x: 120, offset_y: 160}}

      result = GamePage.action(:canvas_pointer_move, params, comp)

      # Strokes unchanged — JS handles SVG directly
      assert result.state.drawing_strokes == []
    end

    test "does nothing when not drawing" do
      comp = drawing_component(%{drawing?: false})
      params = %{event: %{offset_x: 120, offset_y: 160}}

      result = GamePage.action(:canvas_pointer_move, params, comp)

      assert result.state.drawing_strokes == []
    end
  end

  describe "canvas_pointer_up" do
    test "stops drawing" do
      comp = drawing_component(%{drawing?: true})

      result = GamePage.action(:canvas_pointer_up, %{}, comp)

      assert result.state.drawing? == false
    end
  end

  describe "clear_canvas" do
    test "resets strokes to empty" do
      strokes = [%{path: "M 100 150 L 120 160", color: "#000000", width: 2}]
      comp = drawing_component(%{drawing_strokes: strokes})

      result = GamePage.action(:clear_canvas, %{}, comp)

      assert result.state.drawing_strokes == []
    end
  end

  describe "receive_drawing_stroke" do
    test "appends stroke to non-drawer's strokes" do
      comp = drawing_component(%{is_drawer: false})
      params = %{path: "M 10 20 L 30 40", color: "#EF4444", width: 5}

      result = GamePage.action(:receive_drawing_stroke, params, comp)

      assert length(result.state.drawing_strokes) == 1
      [stroke] = result.state.drawing_strokes
      assert stroke.path == "M 10 20 L 30 40"
      assert stroke.color == "#EF4444"
      assert stroke.width == 5
    end

    test "does nothing for drawer" do
      comp = drawing_component(%{is_drawer: true})
      params = %{path: "M 10 20", color: "#000000", width: 2}

      result = GamePage.action(:receive_drawing_stroke, params, comp)

      assert result.state.drawing_strokes == []
    end

    test "accumulates multiple strokes" do
      comp =
        drawing_component(%{
          is_drawer: false,
          drawing_strokes: [
            %{path: "M 1 2", color: "#000000", width: 2}
          ]
        })

      params = %{path: "M 10 20", color: "#3B82F6", width: 10}

      result = GamePage.action(:receive_drawing_stroke, params, comp)

      assert length(result.state.drawing_strokes) == 2
    end
  end

  describe "receive_drawing_clear" do
    test "clears all strokes" do
      comp =
        drawing_component(%{
          drawing_strokes: [
            %{path: "M 1 2", color: "#000000", width: 2}
          ]
        })

      result = GamePage.action(:receive_drawing_clear, %{}, comp)

      assert result.state.drawing_strokes == []
    end
  end

  describe "tool selection actions" do
    test "select_color updates draw_color and disables eraser" do
      comp = drawing_component(%{draw_eraser: true, draw_color: "#000000"})

      result = GamePage.action(:select_color, %{color: "#EF4444"}, comp)

      assert result.state.draw_color == "#EF4444"
      assert result.state.draw_eraser == false
    end

    test "select_width updates draw_width" do
      comp = drawing_component(%{draw_width: 2})

      result = GamePage.action(:select_width, %{width: 10}, comp)

      assert result.state.draw_width == 10
    end

    test "toggle_eraser enables eraser" do
      comp = drawing_component(%{draw_eraser: false})

      result = GamePage.action(:toggle_eraser, %{}, comp)

      assert result.state.draw_eraser == true
    end

    test "toggle_eraser disables eraser on second toggle" do
      comp = drawing_component(%{draw_eraser: true})

      result = GamePage.action(:toggle_eraser, %{}, comp)

      assert result.state.draw_eraser == false
    end
  end
end
