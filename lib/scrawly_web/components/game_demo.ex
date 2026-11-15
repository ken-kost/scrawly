defmodule ScrawlyWeb.Components.GameDemo do
  @moduledoc """
  Shared interactive canvas rendered on the home page. All drawing flows over
  the `demo:board` Phoenix channel — every connected visitor sees and edits the
  same board in real time. Pointer input is native (stroke_engine.mjs) and
  strokes are committed to the DOM directly by `demo_board.mjs`, so Hologram
  never runs an action or re-renders per pointer move.

  The board has the game canvas's coordinates (`viewBox="0 0 800 450"`), so
  a size draws as thick, relative to the canvas, on both. Its tools are the
  game's DrawingToolbar without undo, with its shortcuts (`[` / `]`, B, E;
  draw_controls.mjs ignores them while the user types in the lobby chat,
  the code field or any other field); `tool` is HomePage's `draw_tool`.

  The svg's layers, bottom to top: the JS-owned `#demo-board-strokes` and
  `#demo-board-overlay` groups (JS only inserts into these), then
  `#demo-board-active-path` (styled by JS when a stroke starts). The dot grid
  is drawn by CSS above the strokes (`.demo-canvas::after`), so the white
  eraser never paints over it. `#demo-board-ring`, beside the svg, is the
  size ring (size_ring.mjs, on its own layer, hidden until JS shows it).
  """
  use Hologram.Component

  alias ScrawlyWeb.Components.DrawingToolbar

  prop :tool, :map, required: true

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
      </div>

      <DrawingToolbar tool={@tool} controls={[:colors, :sizes, :eraser, :clear]} shortcuts={true} />
    </div>
    """
  end

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
