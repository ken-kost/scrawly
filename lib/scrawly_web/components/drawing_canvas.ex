defmodule ScrawlyWeb.Components.DrawingCanvas do
  use Hologram.Component

  prop :room_id, :string, default: "test"
  prop :is_drawer, :boolean, default: false
  prop :disabled, :boolean, default: false
  prop :path, :string, default: ""
  prop :drawing?, :boolean, default: false

  def init(params, component, _server) do
    put_state(component, params)
  end

  def action(:clear_canvas, _params, component) do
    put_state(component, drawing?: false, path: "")
  end

  def action(:draw_move, params, %{state: %{drawing?: true}} = component) do
    new_path = component.state.path <> " L #{params.event.offset_x} #{params.event.offset_y}"
    put_state(component, :path, new_path)
  end

  def action(:draw_move, _params, component) do
    component
  end

  def action(:start_drawing, params, component) do
    new_path =
      if component.state.path == "" do
        "M #{params.event.offset_x} #{params.event.offset_y}"
      else
        component.state.path <> " M #{params.event.offset_x} #{params.event.offset_y}"
      end

    put_state(component, drawing?: true, path: new_path)
  end

  def action(:stop_drawing, _params, component) do
    put_state(component, :drawing?, false)
  end

  def template do
    ~HOLO"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h3 class="text-lg font-semibold">Drawing Canvas</h3>
        <button
          $show={@is_drawer && !@disabled}
          $click={action: :clear_canvas, target: "drawing_canvas"}
          class="px-4 py-2 bg-red-500 hover:bg-red-600 text-white rounded disabled:opacity-50">
          Clear
        </button>
      </div>
      <svg
        class="bg-white border border-gray-300 rounded w-full h-96"
        style="touch-action: none;"
      $pointer_down={action: :start_drawing, target: "drawing_canvas"}
    $pointer_move={action: :draw_move, target: "drawing_canvas"}
    $pointer_up={action: :stop_drawing, target: "drawing_canvas"}
    $pointer_cancel={action: :stop_drawing, target: "drawing_canvas"}
      >
        <path d={@path} stroke="#2563eb" stroke-width="2" fill="none" />
      </svg>
    </div>
    """
  end
end
