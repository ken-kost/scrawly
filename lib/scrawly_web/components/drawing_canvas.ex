defmodule ScrawlyWeb.Components.DrawingCanvas do
  @moduledoc """
  SVG drawing canvas supporting multi-stroke rendering with color and width.

  Markup contract with drawing_manager.mjs: the svg is `#game-canvas-svg`;
  viewers get the completed strokes rendered here (`data-stroke-id`); the
  drawer gets `#drawing-path` (the stroke in progress) and their completed
  strokes are drawn by JS before it; everyone gets the empty
  `#game-canvas-overlay` group as the last child, where JS draws live strokes
  from other tabs.
  """
  use Hologram.Component

  prop :is_drawer, :boolean, required: true
  # Not read yet: stroke-engine owns it (and the pointer bindings below).
  prop :disabled, :boolean, default: false
  prop :strokes, :list, required: true
  prop :active_color, :string, default: "#000000"
  prop :active_width, :integer, default: 2

  def template do
    ~HOLO"""
    <div class="canvas-frame">
      <svg
        id="game-canvas-svg"
        viewBox="0 0 800 450"
        preserveAspectRatio="xMidYMid meet"
        style="touch-action: none;"
        $pointer_down.prevent_default={:canvas_pointer_down}
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
        {%if !@is_drawer}
          {%for stroke <- @strokes}
            <path data-stroke-id={stroke.id} d={stroke.path} stroke={stroke.color} stroke-width={stroke.width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
          {/for}
        {/if}
        {%if @is_drawer}
          <path id="drawing-path" stroke={@active_color} stroke-width={@active_width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
        {/if}
        <g id="game-canvas-overlay"></g>
      </svg>
    </div>
    """
  end
end
