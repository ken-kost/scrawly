defmodule ScrawlyWeb.Components.DrawingCanvas do
  @moduledoc """
  SVG drawing canvas supporting multi-stroke rendering with color and width.

  Markup contract with drawing_manager.mjs: the svg is `#game-canvas-svg`.
  Its layers, bottom to top:

    1. `#game-canvas-strokes`: the completed strokes Hologram renders for
       viewers (`data-stroke-id`), in list order: a line stroked, a fill
       (`StrokeRules.fill?/1`, the fill tool's closed shape) filled with its
       colour, evenodd, no outline;
    2. `#game-canvas-drawer` (drawer only inside): the JS-owned
       `#game-canvas-drawer-strokes` group, where the drawer's committed
       strokes are drawn, and `#drawing-path`, the stroke in progress;
    3. `#game-canvas-overlay`, JS-owned, for everyone: live strokes from
       other tabs.

  JS only ever inserts into the two empty groups, and styles `#drawing-path`
  when a stroke starts (the tool in draw_tools.mjs). Pointer input is native
  (stroke_engine.mjs), so there are no pointer bindings here. The dot grid is
  drawn by CSS above the strokes (`.canvas-frame::after`), so the white eraser
  never paints over it.

  Beside the svg, above the grid, `#game-canvas-ring` is the size ring
  (size_ring.mjs): its own small svg on its own composited layer, so moving
  it never repaints the strokes. Hidden until JS shows it (the drawer, in
  `:drawing`, with a mouse or a pen over the canvas). `#game-canvas-pick` is
  the colour picker's swatch beside the pointer (eyedropper.mjs), on its
  own layer too, shown under the same rules while a click would pick.
  `#game-canvas-notice` is an empty status line over the canvas where the
  fill tool (fill_tool.mjs) says, for a moment, why an area wasn't filled.
  """
  use Hologram.Component

  alias Scrawly.Games.StrokeRules

  prop :is_drawer, :boolean, required: true
  prop :strokes, :list, required: true

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
            {%for stroke <- @strokes}{%if StrokeRules.fill?(stroke)}<path data-stroke-id={stroke.id} d={stroke.path} fill={stroke.color} fill-rule="evenodd" stroke="none" />{%else}<path data-stroke-id={stroke.id} d={stroke.path} stroke={stroke.color} stroke-width={stroke.width} fill="none" stroke-linecap="round" stroke-linejoin="round" />{/if}{/for}
          {/if}
        </g>
        <g id="game-canvas-drawer">
          {%if @is_drawer}
            <g id="game-canvas-drawer-strokes"></g>
            <path id="drawing-path" fill="none" stroke-linecap="round" stroke-linejoin="round" />
          {/if}
        </g>
        <g id="game-canvas-overlay"></g>
      </svg>
      <svg id="game-canvas-ring" class="size-ring" aria-hidden="true" focusable="false">
        <circle class="size-ring-outer" />
        <circle class="size-ring-inner" />
      </svg>
      <span id="game-canvas-pick" class="pick-swatch" aria-hidden="true"></span>
      <span id="game-canvas-notice" class="canvas-notice" role="status"></span>
    </div>
    """
  end

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
