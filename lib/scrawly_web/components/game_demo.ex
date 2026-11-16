defmodule ScrawlyWeb.Components.GameDemo do
  @moduledoc """
  Shared interactive canvas rendered on the home page. All drawing flows over
  the `demo:board` Phoenix channel — every connected visitor sees and edits the
  same board in real time. Pointer input is native (stroke_engine.mjs) and
  strokes are committed to the DOM directly by `demo_board.mjs`, so Hologram
  never runs an action or re-renders per pointer move.

  The board has the game canvas's coordinates (`viewBox="0 0 800 450"`), so
  a size draws as thick, relative to the canvas, on both. Its tools are the
  game's DrawingToolbar, every control, with its shortcuts (`[` / `]`, B, E,
  I, F, Ctrl/Cmd+Z; draw_controls.mjs ignores them while the user types in the
  lobby chat, the code field or any other field); `tool` is HomePage's
  `draw_tool`, `saved` and `panel` its saved colours and colour panel flag,
  `can_undo` whether the visitor has a stroke of their own on the board (undo
  takes back only the visitor's own strokes, demo_board.mjs).

  The svg's layers, bottom to top: the JS-owned `#demo-board-strokes` and
  `#demo-board-overlay` groups (JS only inserts into these), then
  `#demo-board-active-path` (styled by JS when a stroke starts). The dot grid
  is drawn by CSS above the strokes (`.demo-canvas::after`), so the white
  eraser never paints over it. `#demo-board-ring`, beside the svg, is the
  size ring (size_ring.mjs, on its own layer, hidden until JS shows it),
  `#demo-board-pick` the colour picker's swatch (eyedropper.mjs, the same),
  and `#demo-board-notice` the fill tool's status line (fill_tool.mjs: why
  an area wasn't filled, for a moment). Fills are strokes like the others
  (demo_board.mjs paints their inside).
  """
  use Hologram.Component

  alias ScrawlyWeb.Components.DrawingToolbar

  prop :tool, :map, required: true
  # HomePage's saved colours and colour panel flag (DrawingToolbar).
  prop :saved, :list, default: []
  prop :panel, :boolean, default: false
  prop :can_undo, :boolean, default: false

  def template do
    ~HOLO"""
    <div class="surface" style="overflow: hidden; display: flex; flex-direction: column;">
      <div class="between" style="padding: 12px 14px; border-bottom: 1px solid var(--hairline);">
        <div class="row" style="gap: 10px;">
          <span class="chip chip-live">live demo</span>
          <span class="section-label">shared board · everyone draws together</span>
        </div>
      </div>

      <div class="demo-canvas" style="aspect-ratio: 16/9; min-height: 220px; position: relative;">
        <svg
          id="demo-board-svg"
          viewBox="0 0 800 450"
          preserveAspectRatio="xMidYMid meet"
          style="touch-action: none; width: 100%; height: 100%;">
          <g id="demo-board-strokes"></g>
          <g id="demo-board-overlay"></g>
          <path id="demo-board-active-path" d="" fill="none" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        <svg id="demo-board-ring" class="size-ring" aria-hidden="true" focusable="false">
          <circle class="size-ring-outer" />
          <circle class="size-ring-inner" />
        </svg>
        <span id="demo-board-pick" class="pick-swatch" aria-hidden="true"></span>
        <span id="demo-board-notice" class="canvas-notice" role="status"></span>
      </div>

      <DrawingToolbar tool={@tool} saved={@saved} panel={@panel} can_undo={@can_undo} shortcuts={true} />
    </div>
    """
  end

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
