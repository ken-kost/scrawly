defmodule ScrawlyWeb.Components.DrawingToolbar do
  @moduledoc """
  The drawing tools under a canvas, for both canvases: the drawer's in-game
  canvas (GamePage) and the home page's shared board (GameDemo). The colour
  list, the size range and the tool model are defined here once.

  The tool model is `%{tool: :brush | :eraser, color: "#rrggbb", size: 1..40}`
  (`default_tool/0`); the size is one for the brush and the eraser. The page
  showing the canvas keeps it in its state as `draw_tool`, passes it in as
  `tool`, changes it with `select_color/2`, `select_size/2` and
  `toggle_eraser/1`, and pushes every change to the canvas:
  `JS.call(:setDrawTool, [js_tool(tool)])` (draw_tools.mjs, which also
  defines the eraser's stroke: white, at the tool's size).

  The size is a slider (`input[data-draw-size]`) with a dot at that size, in
  the tool's colour, and the number. The slider writes the size into
  draw_tools.mjs natively on every `input` (draw_controls.mjs), so it takes
  effect at once; its `$change.throttle(100)` binding brings the page's
  state (and the dot and number) along behind, at most ten actions a second
  while dragging, never one per value.

  Stateless, so its events go to the page, which handles:

    * `:select_color` (`color`): the brush in that colour;
    * `:select_size` (`size`, or the slider's `event.value`, see
      `size_param/1`): that size, brush or eraser alike;
    * `:toggle_eraser`, `:undo_drawing`, `:clear_canvas`.

  With `shortcuts`, the toolbar names its shortcuts in `data-draw-shortcuts`
  and the hint shows them: `[` / `]` the size (with `:sizes`), E the eraser
  (`:eraser`), Ctrl+Z / Cmd+Z undo (`:undo`). draw_controls.mjs handles the
  keys, all of them behind one typing guard (nothing while focus is in a
  text field, a select or a contenteditable), and dispatches the toolbar's
  own actions to the page; the size keys step the slider.

  `controls` lists what the surface offers, in any order: `:colors`,
  `:sizes`, `:eraser`, `:undo`, `:clear` (all by default, `controls/0`). A
  shortcut is live, and named in the hint, only with its control.
  """
  use Hologram.Component

  @controls [:colors, :sizes, :eraser, :undo, :clear]
  @colors ["#0a0a0a", "#d63838", "#2a6df4", "#1f9a4a", "#eab308", "#f97316", "#a855f7", "#ec4899"]
  # In canvas units (both canvases are 800 x 450):
  # Scrawly.Games.StrokeRules.valid_width?/1, MIN_SIZE / MAX_SIZE in
  # draw_tools.mjs.
  @min_size 1
  @max_size 40
  # DEFAULT_TOOL in draw_tools.mjs is the same (a test keeps them equal).
  @default_tool %{tool: :brush, color: "#0a0a0a", size: 4}
  # The shortcuts each control brings, in the hint's order:
  # {control, name in data-draw-shortcuts, keys, label}.
  @shortcuts [
    {:undo, "undo", ["⌘/Ctrl+Z"], "undo"},
    {:eraser, "eraser", ["E"], "eraser"},
    {:sizes, "size", ["[", "]"], "size"}
  ]

  prop :tool, :map, required: true
  prop :controls, :list, default: @controls
  prop :shortcuts, :boolean, default: false

  @doc "Every control a surface can offer."
  def controls, do: @controls

  @doc "The colour presets."
  def colors, do: @colors

  @doc "The smallest size, in canvas units."
  def min_size, do: @min_size

  @doc "The largest size, in canvas units."
  def max_size, do: @max_size

  @doc "The tool a canvas starts with."
  def default_tool, do: @default_tool

  @doc "The brush in `color` (`#rrggbb`); anything else changes nothing."
  def select_color(tool, color) when is_binary(color) and byte_size(color) == 7,
    do: %{tool | tool: :brush, color: color}

  def select_color(tool, _color), do: tool

  @doc """
  The tool at `size`, clamped to the widths the server accepts (1..40). The
  brush stays the brush and the eraser the eraser: they share the size.
  Anything but a whole number changes nothing.
  """
  def select_size(tool, size) when is_integer(size),
    do: %{tool | size: size |> max(@min_size) |> min(@max_size)}

  def select_size(tool, _size), do: tool

  @doc """
  The size a `:select_size` event carries: `size` from a page's own call, or
  the slider's value (`event.value`, a string); nil for anything else.
  """
  def size_param(%{size: size}), do: size

  # String.to_integer/1 is a runtime BIF on the client; Integer.parse/1 would
  # put ~26 KB of compiled Elixir into every page bundle that shows a toolbar.
  def size_param(%{event: %{value: value}}) when is_binary(value) do
    String.to_integer(value)
  rescue
    ArgumentError -> nil
  end

  def size_param(_params), do: nil

  @doc "The eraser, or back to the brush (its colour and size kept)."
  def toggle_eraser(%{tool: :eraser} = tool), do: %{tool | tool: :brush}
  def toggle_eraser(tool), do: %{tool | tool: :eraser}

  @doc "The tool as draw_tools.mjs's `setDrawTool` takes it."
  def js_tool(tool), do: %{tool: Atom.to_string(tool.tool), color: tool.color, size: tool.size}

  @doc """
  The names of the shortcuts `controls` bring, space-separated, as the
  toolbar's `data-draw-shortcuts` (draw_controls.mjs); nil when none.
  """
  def shortcut_names(controls) do
    case for({control, name, _keys, _label} <- @shortcuts, control in controls, do: name) do
      [] -> nil
      names -> Enum.join(names, " ")
    end
  end

  def template do
    ~HOLO"""
    <div class="toolbar" data-draw-shortcuts={if @shortcuts do shortcut_names(@controls) end}>
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
        <div class="tool-group size-control">
          <input type="range" class="size-slider" min={min_size()} max={max_size()} step="1"
                 value={@tool.size} aria-label="size" data-draw-size="size"
                 $change.throttle(100)="select_size" />
          <span class="size-preview"><span class={"size-dot" <> eraser(@tool)} style={dot_style(@tool)}></span></span>
          <span class="size-value mono">{@tool.size}</span>
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
      {%if @shortcuts and hints(@controls) != []}
        <span class="mono toolbar-hint">{%for h <- hints(@controls)}{h.sep}{%for k <- h.keys}<span class="kbd">{k}</span>{/for} {h.label}{/for}</span>
      {/if}
    </div>
    """
  end

  defp active(true), do: " active"
  defp active(_false), do: ""

  defp eraser(%{tool: :eraser}), do: " eraser"
  defp eraser(_tool), do: ""

  # The dot beside the slider, in px: 2 at size 1 up to 24 at size 40
  # (linear), in the brush's colour (the eraser's is white, dashed, app.css).
  defp dot_style(tool) do
    px = Integer.to_string(round(2 + (tool.size - @min_size) * 22 / (@max_size - @min_size)))
    size = "width: " <> px <> "px; height: " <> px <> "px;"

    case tool do
      %{tool: :eraser} -> size
      %{color: color} -> size <> " background: " <> color <> ";"
    end
  end

  # The hint's entries for the shortcuts `controls` bring.
  defp hints(controls) do
    @shortcuts
    |> Enum.filter(fn {control, _name, _keys, _label} -> control in controls end)
    |> Enum.with_index()
    |> Enum.map(fn {{_control, _name, keys, label}, i} ->
      %{keys: keys, label: label, sep: if(i == 0, do: "", else: " · ")}
    end)
  end

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
