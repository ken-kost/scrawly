defmodule ScrawlyWeb.Components.DrawingCanvas do
  @moduledoc "SVG drawing canvas supporting multi-stroke rendering with color and width."
  use Hologram.Component

  prop :room_id, :string, default: "test"
  prop :is_drawer, :boolean, default: false
  prop :disabled, :boolean, default: false
  prop :strokes, :list, default: []
  prop :active_color, :string, default: "#000000"
  prop :active_width, :integer, default: 2

  def template do
    ~HOLO"""
    <div class="canvas-frame">
      <svg
        viewBox="0 0 800 450"
        preserveAspectRatio="xMidYMid meet"
        style="touch-action: none;"
        $pointer_down={:canvas_pointer_down}
        $pointer_move={:canvas_pointer_move}
        $pointer_up={:canvas_pointer_up}
        $pointer_cancel={:canvas_pointer_up}
      >
        <defs>
          <pattern id="canvas-grid" x="0" y="0" width="20" height="20" patternUnits="userSpaceOnUse">
            <circle cx="1" cy="1" r="0.5" fill="rgba(0,0,0,0.05)" />
          </pattern>
        </defs>
        <rect width="800" height="450" fill="url(#canvas-grid)" />
        {%for stroke <- @strokes}
          <path d={stroke.path} stroke={stroke.color} stroke-width={stroke.width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
        {/for}
        {%if @is_drawer}
          <path id="drawing-path" stroke={@active_color} stroke-width={@active_width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
        {/if}
      </svg>
    </div>
    """
  end
end
