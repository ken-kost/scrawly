defmodule ScrawlyWeb.Components.DrawingToolbar do
  @moduledoc """
  The drawing tools under a canvas, for both canvases: the drawer's in-game
  canvas (GamePage) and the home page's shared board (GameDemo). The colour
  presets, the size range and the tool model are defined here once.

  The tool model is `%{tool: :brush | :eraser, color: "#rrggbb", size: 1..40}`
  (`default_tool/0`); the size is one for the brush and the eraser, and the
  colour any `#rrggbb`. The page showing the canvas keeps it in its state as
  `draw_tool`, passes it in as `tool`, changes it with `select_color/2`,
  `select_size/2`, `select_brush/1` and `toggle_eraser/1`, and pushes every
  change to the canvas:
  `JS.call(:setDrawTool, [js_tool(tool)])` (draw_tools.mjs, which also
  defines the eraser's stroke: white, at the tool's size).

  The size is a slider (`input[data-draw-size]`) with a dot at that size, in
  the tool's colour, and the number. The slider writes the size into
  draw_tools.mjs natively on every `input` (draw_controls.mjs), so it takes
  effect at once; its `$change.throttle(100)` binding brings the page's
  state (and the dot and number) along behind, at most ten actions a second
  while dragging, never one per value.

  ## Colours

  * 24 presets (`presets/0`, each with its accessible name), in a grid of 2
    rows of 12, and the page's saved colours (`saved`, newest first) as a
    third row, each removable (its x, or Delete on the swatch).
  * The colour chip (`button[data-color-open]`) always shows the tool's
    colour, preset or not, and opens the colour panel: a hue and saturation
    wheel (a `<canvas>`) with a brightness slider, the new colour beside the
    one the panel opened with, a hex field and "+ save".
  * The panel's controls are native (color_picker.mjs builds them into
    `[data-color-pick]`): they write the tool model at once and bring the
    page's state along with `:color_picked`, throttled; no action per
    pointer move.
  * Saved colours live in the browser (localStorage, color_picker.mjs), so
    they are per-browser and never in server-rendered state: the page loads
    them after mount (`saved` is `[]` until then), and "+ save" and the
    removals send the new list (`:saved_colors`).
  * Wide screens: the grid inline, the panel a popover over the canvas.
    Phones (app.css, 720 px): the chip alone in the toolbar; it opens one
    sheet with the presets, the saved colours and the wheel.
  * The panel (`panel`, the page's `color_panel`) closes on Escape, on a
    click outside, and with "done" (phones).
  * The swatch grid is one Tab stop (the first preset); the arrow keys move
    between the swatches (color_picker.mjs).

  Stateless, so its events go to the page, which handles:

    * `:select_color` (`color`): the brush in that colour (a preset, a
      saved colour);
    * `:color_picked` (`color`): the same, from the panel's native controls,
      which have already set the model (no push);
    * `:toggle_color_panel`, `:close_color_panel`;
    * `:saved_colors` (`colors`): the saved list after "+ save" or a removal
      (color_picker.mjs has stored it);
    * `:select_size` (`size`, or the slider's `event.value`, see
      `size_param/1`): that size, brush or eraser alike;
    * `:toggle_eraser`, `:undo_drawing`, `:clear_canvas`;
    * `:select_brush` (B, see below).

  A gesture pressed with the right mouse button, or with Ctrl held, erases
  without selecting the eraser (draw_tools.mjs `gestureTool`): the tool
  shown here doesn't change for it.

  With `shortcuts`, the toolbar names its shortcuts in `data-draw-shortcuts`
  and the hint shows them: `[` / `]` the size (with `:sizes`), B the brush
  and E the eraser, a toggle like its button (both with `:eraser`), Ctrl+Z /
  Cmd+Z undo (`:undo`). draw_controls.mjs handles the
  keys, all of them behind one typing guard (nothing while focus is in a
  text field, a select or a contenteditable), and dispatches the toolbar's
  own actions to the page; the size keys step the slider.

  `controls` lists what the surface offers, in any order: `:colors`,
  `:sizes`, `:eraser`, `:undo`, `:clear` (all by default, `controls/0`). A
  shortcut is live, and named in the hint, only with its control.
  """
  use Hologram.Component

  @controls [:colors, :sizes, :eraser, :undo, :clear]
  # The presets, {colour, accessible name}: the darker row, then the lighter
  # one, column by column (black over white, dark grey over light grey).
  @presets [
    {"#0a0a0a", "black"},
    {"#525252", "dark grey"},
    {"#6b3a1e", "brown"},
    {"#8d5a3b", "dark skin"},
    {"#dc2626", "dark red"},
    {"#ea580c", "dark orange"},
    {"#ca8a04", "dark yellow"},
    {"#16a34a", "dark green"},
    {"#0891b2", "dark cyan"},
    {"#2563eb", "dark blue"},
    {"#9333ea", "dark purple"},
    {"#db2777", "dark pink"},
    {"#ffffff", "white"},
    {"#d4d4d4", "light grey"},
    {"#a3a3a3", "grey"},
    {"#f1c7a5", "light skin"},
    {"#fca5a5", "light red"},
    {"#fdba74", "light orange"},
    {"#fde047", "light yellow"},
    {"#86efac", "light green"},
    {"#67e8f9", "light cyan"},
    {"#93c5fd", "light blue"},
    {"#d8b4fe", "light purple"},
    {"#f9a8d4", "light pink"}
  ]
  @colors Enum.map(@presets, &elem(&1, 0))
  @first_color hd(@colors)
  # MAX_SAVED in colors.mjs.
  @max_saved 12
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
    {:eraser, "brush", ["B"], "brush"},
    {:eraser, "eraser", ["E"], "eraser"},
    {:sizes, "size", ["[", "]"], "size"}
  ]

  prop :tool, :map, required: true
  prop :controls, :list, default: @controls
  prop :shortcuts, :boolean, default: false
  # The page's saved colours (color_picker.mjs), and whether its colour
  # panel is open.
  prop :saved, :list, default: []
  prop :panel, :boolean, default: false

  @doc "Every control a surface can offer."
  def controls, do: @controls

  @doc "The colour presets, `{colour, accessible name}`, in the grid's order."
  def presets, do: @presets

  @doc "The presets' colours."
  def colors, do: @colors

  @doc "How many saved colours are kept (colors.mjs `MAX_SAVED`)."
  def max_saved, do: @max_saved

  @doc "The smallest size, in canvas units."
  def min_size, do: @min_size

  @doc "The largest size, in canvas units."
  def max_size, do: @max_size

  @doc "The tool a canvas starts with."
  def default_tool, do: @default_tool

  @doc """
  The brush in `color`, any `#rrggbb` (either case, as
  `Scrawly.Games.StrokeRules.valid_color?/1`); anything else changes
  nothing.
  """
  def select_color(tool, color) do
    if hex_color?(color), do: %{tool | tool: :brush, color: color}, else: tool
  end

  @doc "Whether `color` is a `#rrggbb` colour, in either case."
  # String.to_integer/2 is the runtime's binary_to_integer BIF (no Regex on
  # the client); the "1" in front keeps it from reading a sign.
  def hex_color?(<<?#, digits::binary-size(6)>>) do
    is_integer(String.to_integer("1" <> digits, 16))
  rescue
    ArgumentError -> false
  end

  def hex_color?(_color), do: false

  @doc """
  The saved colours from what color_picker.mjs returned or sent: its
  `#rrggbb` entries, at most `max_saved/0`; nil when it is no list (on the
  server `JS.call/2` returns `:ok`), so the page keeps what it shows.
  """
  def saved_colors(colors) when is_list(colors),
    do: colors |> Enum.filter(&hex_color?/1) |> Enum.take(@max_saved)

  def saved_colors(_value), do: nil

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

  @doc "The brush, in its colour and at the size (B)."
  def select_brush(tool), do: %{tool | tool: :brush}

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
        <div class={"color-control" <> open(@panel)} data-color-control $click_outside={if @panel do :close_color_panel end}>
          <button type="button" class="tool-btn color-chip" data-color-open aria-haspopup="dialog" aria-controls="color-sheet"
                  aria-expanded={if @panel do "true" else "false" end} aria-label={"colour " <> @tool.color <> ", more colours"}
                  $click="toggle_color_panel"><span class="color-chip-dot" style={"background: " <> @tool.color <> ";"}></span><span class="color-chip-label">custom</span></button>
          {%if @panel}<window $key_down.escape="close_color_panel" /><div class="color-backdrop" $click="close_color_panel"></div>{/if}
          <div class="color-sheet" id="color-sheet" role="dialog" aria-label="colours">
            <div class="color-sheet-head"><span class="section-label">colours</span><button type="button" class="tool-btn" $click="close_color_panel">done</button></div>
            <div class="color-grid" data-swatch-grid>
              <div class="swatches" role="group" aria-label="colours">{%for {c, name} <- presets()}<button type="button"
                  class={swatch_class(@tool, c)} style={"background: " <> c <> ";"}
                  aria-label={name} title={name} tabindex={tab_stop(c)}
                  $click={:select_color, color: c}></button>{/for}</div>
              <div class="saved-colors" role="group" aria-label="my colours">{%for c <- @saved}<span class="saved-item"><button type="button"
                  class={swatch_class(@tool, c)} style={"background: " <> c <> ";"}
                  aria-label={"my colour " <> c} title={c} aria-keyshortcuts="Delete" tabindex="-1" data-saved-color={c}
                  $click={:select_color, color: c}></button><button type="button" class="saved-remove" tabindex="-1"
                  aria-label={"remove " <> c} data-color-forget={c}>×</button></span>{/for}</div>
            </div>
            <div class="color-panel"><div class="color-pick" data-color-pick></div></div>
          </div>
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

  defp open(true), do: " open"
  defp open(_false), do: ""

  # A swatch is marked while the brush draws in its colour.
  defp swatch_class(%{tool: :brush, color: color}, color), do: "swatch active"
  defp swatch_class(_tool, _color), do: "swatch"

  # The swatch grid is one Tab stop, the first preset; the arrow keys move
  # inside it (color_picker.mjs).
  defp tab_stop(@first_color), do: "0"
  defp tab_stop(_color), do: "-1"

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
