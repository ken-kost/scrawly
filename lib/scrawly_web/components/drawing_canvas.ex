defmodule ScrawlyWeb.Components.DrawingCanvas do
  @moduledoc """
  SVG drawing canvas supporting multi-stroke rendering with color and width.

  Markup contract with drawing_manager.mjs: the svg is `#game-canvas-svg`.
  Its layers, bottom to top:

    1. `#game-canvas-strokes`: the completed strokes Hologram renders for
       viewers (`data-stroke-id`);
    2. `#game-canvas-drawer` (drawer only inside): the JS-owned
       `#game-canvas-drawer-strokes` group, where the drawer's committed
       strokes are drawn, and `#drawing-path`, the stroke in progress;
    3. `#game-canvas-overlay`, JS-owned, for everyone: live strokes from
       other tabs.

  JS only ever inserts into the two empty groups. Pointer input is native
  (stroke_engine.mjs), so there are no pointer bindings here. The dot grid is
  drawn by CSS above the strokes (`.canvas-frame::after`), so the white eraser
  never paints over it.
  """
  use Hologram.Component

  prop :is_drawer, :boolean, required: true
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
      >
        <g id="game-canvas-strokes">
          {%if !@is_drawer}
            {%for stroke <- @strokes}
              <path data-stroke-id={stroke.id} d={stroke.path} stroke={stroke.color} stroke-width={stroke.width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
            {/for}
          {/if}
        </g>
        <g id="game-canvas-drawer">
          {%if @is_drawer}
            <g id="game-canvas-drawer-strokes"></g>
            <path id="drawing-path" stroke={@active_color} stroke-width={@active_width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
          {/if}
        </g>
        <g id="game-canvas-overlay"></g>
      </svg>
    </div>
    """
  end
end
