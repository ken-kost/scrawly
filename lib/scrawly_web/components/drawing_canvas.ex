defmodule ScrawlyWeb.Components.DrawingCanvas do
  @moduledoc """
  SVG drawing canvas supporting multi-stroke rendering with color and width.

  Markup contract with drawing_manager.mjs: two svgs stacked in the frame,
  with the same viewBox, so a point is the same on both.

    1. `#game-canvas-paint`, below: the committed strokes, never touched by
       a pointer (`pointer-events: none`), all of them JS-owned (one node
       per stroke, `data-stroke-id`, in list order: a line stroked, a fill
       filled with its colour, evenodd, no outline): `#game-canvas-strokes`
       a viewer's, `#game-canvas-drawer` (drawer only inside) the
       `#game-canvas-drawer-strokes` group, the drawer's. Hologram never
       renders a stroke: the canvas arrives as JSON in the page's state and
       drawing_manager.mjs draws it, then follows the room's broadcasts, so
       a stroke, an undo or a countdown tick re-renders no stroke.
    2. `#game-canvas-svg`, on top: the canvas the stroke engine listens to
       and maps pointers on, holding only what changes while drawing:
       `#drawing-path`, the stroke in progress (drawer only), and
       `#game-canvas-overlay`, JS-owned, for everyone: live strokes from
       other tabs. Its own compositor layer (app.css `.canvas-input`), so a
       frame of a stroke in progress re-rasters that stroke alone, never
       the committed strokes under it (notes/files/drawing-benchmarks.md,
       "Rendering decision"); and the cursor attributes the tools set on it
       (`data-size-ring`, `data-pick`, `data-fill`) restyle its few
       children, not every committed stroke.

  JS only ever inserts into the empty groups, and styles `#drawing-path`
  when a stroke starts (the tool in draw_tools.mjs). Pointer input is native
  (stroke_engine.mjs), so there are no pointer bindings here. The dot grid is
  drawn by CSS above the strokes (`.canvas-frame::after`), so the white eraser
  never paints over it.

  Beside the svgs, above the grid, `#game-canvas-ring` is the size ring
  (size_ring.mjs): its own small svg on its own composited layer, so moving
  it never repaints the strokes. Hidden until JS shows it (the drawer, in
  `:drawing`, with a mouse or a pen over the canvas). `#game-canvas-pick` is
  the colour picker's swatch beside the pointer (eyedropper.mjs), on its
  own layer too, shown under the same rules while a click would pick.
  `#game-canvas-notice` is an empty status line over the canvas where the
  fill tool (fill_tool.mjs) says, for a moment, why an area wasn't filled.
  """
  use Hologram.Component

  prop :is_drawer, :boolean, required: true

  def template do
    ~HOLO"""
    <div class="canvas-frame">
      <svg id="game-canvas-paint" class="canvas-paint" viewBox="0 0 800 450" preserveAspectRatio="xMidYMid meet" aria-hidden="true">
        <g id="game-canvas-strokes"></g>
        <g id="game-canvas-drawer">{%if @is_drawer}<g id="game-canvas-drawer-strokes"></g>{/if}</g>
      </svg>
      <svg id="game-canvas-svg" class="canvas-input" viewBox="0 0 800 450" preserveAspectRatio="xMidYMid meet" style="touch-action: none;">
        <g id="game-canvas-active">{%if @is_drawer}<path id="drawing-path" fill="none" stroke-linecap="round" stroke-linejoin="round" />{/if}</g>
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
