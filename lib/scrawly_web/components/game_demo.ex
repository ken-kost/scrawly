defmodule ScrawlyWeb.Components.GameDemo do
  @moduledoc """
  Shared interactive canvas rendered on the home page. All drawing flows over
  the `demo:board` Phoenix channel — every connected visitor sees and edits the
  same board in real time. Strokes are committed to the DOM directly by
  `demo_board.mjs` so Hologram never re-renders per pointer move.
  """
  use Hologram.Component

  prop :color, :string, default: "#000000"
  prop :width, :integer, default: 2
  prop :eraser, :boolean, default: false

  @palette [
    "#000000",
    "#EF4444",
    "#F97316",
    "#EAB308",
    "#22C55E",
    "#3B82F6",
    "#A855F7",
    "#EC4899"
  ]
  @widths [2, 4, 8]

  def template do
    ~HOLO"""
    <div class="surface" style="overflow: hidden; display: flex; flex-direction: column;">
      <div class="between" style="padding: 12px 14px; border-bottom: 1px solid var(--hairline);">
        <div class="row" style="gap: 10px;">
          <span class="chip chip-live">live demo</span>
          <span class="section-label">shared board · everyone draws together</span>
        </div>
        <button type="button" class="app-btn app-btn-ghost app-btn-sm" $click={:demo_clear}>clear</button>
      </div>

      <div class="demo-canvas" style="aspect-ratio: 16/9; min-height: 220px; position: relative;">
        <svg
          id="demo-board-svg"
          viewBox="0 0 400 225"
          preserveAspectRatio="xMidYMid meet"
          style="touch-action: none; width: 100%; height: 100%;"
          $pointer_down={:demo_pointer_down}
          $pointer_move={:demo_pointer_move}
          $pointer_up={:demo_pointer_up}
          $pointer_cancel={:demo_pointer_up}>
          <defs>
            <pattern id="demo-board-dotgrid" x="0" y="0" width="14" height="14" patternUnits="userSpaceOnUse">
              <circle cx="1" cy="1" r="0.6" fill="rgba(0,0,0,0.06)" />
            </pattern>
          </defs>
          <rect width="400" height="225" fill="url(#demo-board-dotgrid)" />
          <path id="demo-board-active-path" d="" stroke={@color} stroke-width={@width} fill="none" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </div>

      <div class="between" style="padding: 10px 14px; gap: 12px; flex-wrap: wrap;">
        <div class="row" style="gap: 4px;">
          {%for c <- ["#000000", "#EF4444", "#F97316", "#EAB308", "#22C55E", "#3B82F6", "#A855F7", "#EC4899"]}
            <button
              type="button"
              class={"swatch " <> if(@color == c and !@eraser, do: "active", else: "")}
              style={"background: " <> c <> ";"}
              $click={:demo_set_color, value: c}></button>
          {/for}
        </div>

        <div class="row" style="gap: 4px;">
          {%for {wv, lbl} <- [{2, "s"}, {4, "m"}, {8, "l"}]}
            <button
              type="button"
              class={"tool-btn " <> if(@width == wv and !@eraser, do: "active", else: "")}
              $click={:demo_set_width, value: wv}>
              <span class="size-dot" style={"width: " <> Integer.to_string(wv * 2) <> "px; height: " <> Integer.to_string(wv * 2) <> "px;"}></span>
              <span class="mono" style="font-size: 11px; color: var(--muted); margin-left: 4px;">{lbl}</span>
            </button>
          {/for}
        </div>

        <button
          type="button"
          class={"tool-btn " <> if(@eraser, do: "active", else: "")}
          $click={:demo_toggle_eraser}>erase</button>
      </div>
    </div>
    """
  end

  def palette, do: @palette
  def widths, do: @widths
end
