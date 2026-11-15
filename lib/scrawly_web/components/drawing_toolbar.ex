defmodule ScrawlyWeb.Components.DrawingToolbar do
  @moduledoc """
  The drawing tools under a canvas, for both canvases: the drawer's in-game
  canvas (GamePage) and the home page's shared board (GameDemo). The colour
  list, the size list and the tool model are defined here once.

  The tool model is `%{tool: :brush | :eraser, color: "#rrggbb", size: 1..40}`
  (`default_tool/0`). The page showing the canvas keeps it in its state as
  `draw_tool`, passes it in as `tool`, changes it with `select_color/2`,
  `select_size/2` and `toggle_eraser/1`, and pushes every change to the
  canvas: `JS.call(:setDrawTool, [js_tool(tool)])` (draw_tools.mjs, which
  also defines the eraser's stroke: white, at a fixed width).

  Stateless, so its events go to the page, which handles:

    * `:select_color` (`color`), `:select_size` (`size`): the brush, in that
      colour or at that size;
    * `:toggle_eraser`, `:undo_drawing`, `:clear_canvas`;
    * with `shortcuts`: `:shortcut_eraser` (E) and `:shortcut_undo` (Ctrl+Z
      / Cmd+Z, `via: :ctrl | :meta`). Their key filters match a superset of
      modifiers and fire on auto-repeat, so the page's actions keep only the
      plain press. They listen on `<window>`, so a surface turns them on only
      where nothing can be typed while the toolbar is shown (in the game the
      drawer's chat input is disabled).

  `controls` lists what the surface offers, in any order: `:colors`,
  `:sizes`, `:eraser`, `:undo`, `:clear` (all by default, `controls/0`). A
  shortcut is bound, and named in the hint, only with its control.
  """
  use Hologram.Component

  @controls [:colors, :sizes, :eraser, :undo, :clear]
  @colors ["#0a0a0a", "#d63838", "#2a6df4", "#1f9a4a", "#eab308", "#f97316", "#a855f7", "#ec4899"]
  # In canvas units: both canvases are 800 x 450.
  @sizes [2, 5, 10, 20]
  # DEFAULT_TOOL in draw_tools.mjs is the same (a test keeps them equal).
  @default_tool %{tool: :brush, color: "#0a0a0a", size: 2}

  prop :tool, :map, required: true
  prop :controls, :list, default: @controls
  prop :shortcuts, :boolean, default: false

  @doc "Every control a surface can offer."
  def controls, do: @controls

  @doc "The colour presets."
  def colors, do: @colors

  @doc "The brush sizes offered, in canvas units."
  def sizes, do: @sizes

  @doc "The tool a canvas starts with."
  def default_tool, do: @default_tool

  @doc "The brush in `color` (`#rrggbb`); anything else changes nothing."
  def select_color(tool, color) when is_binary(color) and byte_size(color) == 7,
    do: %{tool | tool: :brush, color: color}

  def select_color(tool, _color), do: tool

  @doc """
  The brush at `size` (any width the server accepts, 1..40); anything else
  changes nothing.
  """
  def select_size(tool, size) when is_integer(size) and size >= 1 and size <= 40,
    do: %{tool | tool: :brush, size: size}

  def select_size(tool, _size), do: tool

  @doc "The eraser, or back to the brush (its colour and size kept)."
  def toggle_eraser(%{tool: :eraser} = tool), do: %{tool | tool: :brush}
  def toggle_eraser(tool), do: %{tool | tool: :eraser}

  @doc "The tool as draw_tools.mjs's `setDrawTool` takes it."
  def js_tool(tool), do: %{tool: Atom.to_string(tool.tool), color: tool.color, size: tool.size}

  def template do
    ~HOLO"""
    <div class="toolbar">
      {%if :colors in @controls}
        <div class="swatches">
          {%for c <- colors()}
            <button type="button" class={"swatch" <> active(@tool.tool == :brush and @tool.color == c)}
                    style={"background: " <> c <> ";"}
                    $click={:select_color, color: c}></button>
          {/for}
        </div>
      {/if}
      {%if :sizes in @controls}
        <div class="tool-group">
          {%for s <- sizes()}
            <button type="button" class={"tool-btn" <> active(@tool.tool == :brush and @tool.size == s)}
                    $click={:select_size, size: s}>
              <span class="size-dot" style={dot_style(s)}></span>
            </button>
          {/for}
        </div>
      {/if}
      {%if :eraser in @controls or :undo in @controls or :clear in @controls}
        <div class="tool-group">
          {%if :eraser in @controls}
            <button type="button" class={"tool-btn" <> active(@tool.tool == :eraser)} $click={:toggle_eraser}>erase</button>
          {/if}
          {%if :undo in @controls}
            <button type="button" class="tool-btn" $click={:undo_drawing}>undo</button>
          {/if}
          {%if :clear in @controls}
            <button type="button" class="tool-btn" $click={:clear_canvas}>clear</button>
          {/if}
        </div>
      {/if}
      {%if @shortcuts and (:undo in @controls or :eraser in @controls)}
        <span class="mono" style="font-size: 11px; color: var(--muted); margin-left: auto;">
          {%if :undo in @controls}<span class="kbd">⌘/Ctrl+Z</span> undo{/if}{%if :undo in @controls and :eraser in @controls} · {/if}{%if :eraser in @controls}<span class="kbd">E</span> eraser{/if}
        </span>
      {/if}
      {%if @shortcuts and :eraser in @controls}
        <window $key_down.e="shortcut_eraser" />
      {/if}
      {%if @shortcuts and :undo in @controls}
        <window
          $key_down.ctrl+z.prevent_default={:shortcut_undo, via: :ctrl}
          $key_down.meta+z.prevent_default={:shortcut_undo, via: :meta} />
      {/if}
    </div>
    """
  end

  defp active(true), do: " active"
  defp active(_false), do: ""

  # The dot on a size's button, in px: 4 for size 2 up to 14 for size 20
  # (proportional to the square root of the size).
  defp dot_style(size) do
    px = Integer.to_string(round(3.1 * :math.pow(size, 0.5)))
    "width: " <> px <> "px; height: " <> px <> "px;"
  end

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
