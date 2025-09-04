defmodule ScrawlyWeb.Components.DrawingCanvasTest do
  use ExUnit.Case, async: true

  alias ScrawlyWeb.Components.DrawingCanvas

  describe "init/3" do
    test "initializes with empty drawing state" do
      component = %{state: %{}}
      result = DrawingCanvas.init(%{drawing?: false, path: ""}, component, nil)

      assert result.state.drawing? == false
      assert result.state.path == ""
    end
  end

  describe "actions" do
    test "start_drawing begins drawing and adds move command to path" do
      component = %{state: %{drawing?: false, path: ""}}
      params = %{event: %{offset_x: 100, offset_y: 150}}

      result = DrawingCanvas.action(:start_drawing, params, component)

      assert result.state.drawing? == true
      assert result.state.path == "M 100 150"
    end

    test "draw_move adds line command when drawing" do
      component = %{state: %{drawing?: true, path: "M 100 150"}}
      params = %{event: %{offset_x: 120, offset_y: 160}}

      result = DrawingCanvas.action(:draw_move, params, component)

      assert result.state.drawing? == true
      assert result.state.path == "M 100 150 L 120 160"
    end

    test "draw_move does nothing when not drawing" do
      component = %{state: %{drawing?: false, path: "M 100 150"}}
      params = %{event: %{offset_x: 120, offset_y: 160}}

      result = DrawingCanvas.action(:draw_move, params, component)

      assert result.state.drawing? == false
      assert result.state.path == "M 100 150"
    end

    test "stop_drawing ends drawing state" do
      component = %{state: %{drawing?: true, path: "M 100 150 L 120 160"}}

      result = DrawingCanvas.action(:stop_drawing, %{}, component)

      assert result.state.drawing? == false
      assert result.state.path == "M 100 150 L 120 160"
    end

    test "clear_canvas resets drawing state and path" do
      component = %{state: %{drawing?: true, path: "M 100 150 L 120 160"}}

      result = DrawingCanvas.action(:clear_canvas, %{}, component)

      assert result.state.drawing? == false
      assert result.state.path == ""
    end
  end
end
