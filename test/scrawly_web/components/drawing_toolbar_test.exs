defmodule ScrawlyWeb.Components.DrawingToolbarTest do
  @moduledoc """
  The drawing toolbar shared by the game (the drawer's tools) and the home
  page's board (draw-toolbar, brush-size): one colour list, one size slider
  (1..40, one size for the brush and the eraser) and one tool model; the
  controls and shortcuts each surface turns on; the pages' tool actions,
  which push the tool to draw_tools.mjs; the two canvases' common
  coordinates, and the size ring beside each canvas.

  `JS.call` is a server-side no-op; `js_calls/1` traces it to see which JS
  functions an action would call.
  """
  # js_calls/1 traces Hologram.JS.call/4 globally.
  use ExUnit.Case, async: false

  import Scrawly.JsCallTrace, only: [js_calls: 1]

  alias Hologram.Component
  alias Hologram.Template.Renderer
  alias ScrawlyWeb.Components.{DrawingCanvas, DrawingToolbar, GameDemo}
  alias ScrawlyWeb.Pages.{GamePage, HomePage}

  @root Path.expand("../../..", __DIR__)
  @brush %{tool: :brush, color: "#2a6df4", size: 10}
  @eraser %{@brush | tool: :eraser}

  defp render_dom(node) do
    {html, _registry, _server} = Renderer.render_dom(node, %Renderer.Env{}, %Hologram.Server{})
    html
  end

  defp toolbar(props) do
    %{controls: DrawingToolbar.controls(), shortcuts: false}
    |> Map.merge(props)
    |> then(&DrawingToolbar.template().(&1))
    |> render_dom()
  end

  # The game's toolbar as GamePage renders it for the drawer.
  defp game_toolbar(tool), do: toolbar(%{tool: tool, shortcuts: true})

  defp board(tool), do: render_dom(GameDemo.template().(%{tool: tool}))

  defp canvas, do: render_dom(DrawingCanvas.template().(%{is_drawer: true, strokes: []}))

  defp swatches(html),
    do:
      Regex.scan(~r/class="swatch[^"]*" style="background: (#[0-9a-f]{6});"/, html,
        capture: :all_but_first
      )

  defp sliders(html), do: Regex.scan(~r/<input[^>]*class="size-slider"[^>]*>/, html)

  defp attr(tag, name) do
    case Regex.run(~r/\s#{name}="([^"]*)"/, tag, capture: :all_but_first) do
      [value] -> value
      nil -> nil
    end
  end

  # The active buttons, with their text.
  defp active(html),
    do: Regex.scan(~r/class="(?:swatch|tool-btn) active"[^>]*>\s*([^<]*?)\s*</, html)

  defp toolbar_tag(html), do: hd(Regex.run(~r/<div class="toolbar"[^>]*>/, html))

  describe "one toolbar for both canvases" do
    test "the game and the board show the same colours and the same size slider" do
      game = game_toolbar(DrawingToolbar.default_tool())
      board = board(DrawingToolbar.default_tool())

      colors = Enum.map(DrawingToolbar.colors(), &[&1])
      assert swatches(game) == colors
      assert swatches(board) == colors

      for html <- [game, board] do
        assert [[slider]] = sliders(html)
        assert attr(slider, "type") == "range"
        assert attr(slider, "min") == "1"
        assert attr(slider, "max") == "40"
        assert attr(slider, "step") == "1"
        assert attr(slider, "data-draw-size") == "size"
        assert attr(slider, "aria-label") == "size"
        refute html =~ ~s(class="tool-btn"><span class="size-dot")

        assert html =~ ~s(<div class="swatches">)
        assert html =~ ">erase</button>"
        assert html =~ ">clear</button>"
      end
    end

    test "8 colours, sizes 1 to 40, the brush in the first colour at 4" do
      assert length(DrawingToolbar.colors()) == 8
      assert DrawingToolbar.colors() == Enum.uniq(DrawingToolbar.colors())
      assert Enum.all?(DrawingToolbar.colors(), &Scrawly.Games.StrokeRules.valid_color?/1)

      assert {DrawingToolbar.min_size(), DrawingToolbar.max_size()} == {1, 40}

      for size <- DrawingToolbar.min_size()..DrawingToolbar.max_size() do
        assert Scrawly.Games.StrokeRules.valid_width?(size)
      end

      refute Scrawly.Games.StrokeRules.valid_width?(DrawingToolbar.min_size() - 1)
      refute Scrawly.Games.StrokeRules.valid_width?(DrawingToolbar.max_size() + 1)

      assert DrawingToolbar.default_tool() == %{
               tool: :brush,
               color: hd(DrawingToolbar.colors()),
               size: 4
             }
    end

    test "draw_tools.mjs falls back to the same default tool and the same size range" do
      js = File.read!(Path.join(@root, "lib/scrawly_web/pages/draw_tools.mjs"))
      %{tool: tool, color: color, size: size} = DrawingToolbar.default_tool()

      assert js =~
               ~s|export const DEFAULT_TOOL = Object.freeze({ tool: "#{tool}", color: "#{color}", size: #{size} });|

      assert js =~ "export const MIN_SIZE = #{DrawingToolbar.min_size()};"
      assert js =~ "export const MAX_SIZE = #{DrawingToolbar.max_size()};"
    end
  end

  describe "the size slider" do
    test "it shows the model's size, for the brush and the eraser alike" do
      for size <- [1, 4, 17, 40], tool <- [@brush, @eraser] do
        html = toolbar(%{tool: %{tool | size: size}})
        [[slider]] = sliders(html)
        assert attr(slider, "value") == Integer.to_string(size)
        assert html =~ ~s(<span class="size-value mono">#{size}</span>)
      end
    end

    test "the dot beside it grows with the size, in the brush's colour" do
      dots =
        for size <- [1, 4, 10, 20, 40] do
          html = toolbar(%{tool: %{@brush | size: size}})

          [px, color] =
            Regex.run(
              ~r/class="size-dot" style="width: (\d+)px; height: \1px; background: (#[0-9a-f]{6});"/,
              html,
              capture: :all_but_first
            )

          assert color == @brush.color
          String.to_integer(px)
        end

      assert dots == [2, 4, 7, 13, 24]
    end

    test "the eraser's dot is the eraser's (white, dashed: app.css), at the same size" do
      html = toolbar(%{tool: %{@eraser | size: 40}})
      assert html =~ ~s(class="size-dot eraser" style="width: 24px; height: 24px;")
    end

    test "it updates the model natively and the page's state throttled, never per value" do
      source = File.read!(Path.join(@root, "lib/scrawly_web/components/drawing_toolbar.ex"))
      assert source =~ ~s|$change.throttle(100)="select_size"|

      js = File.read!(Path.join(@root, "lib/scrawly_web/pages/draw_controls.mjs"))
      assert js =~ ~s|window.addEventListener("input", onInput, true);|
    end
  end

  describe "the selected tool" do
    test "the brush marks its colour" do
      html = toolbar(%{tool: @brush})
      assert [[_swatch, ""]] = active(html)
      assert html =~ ~s(class="swatch active" style="background: #2a6df4;")
      refute html =~ ~s(class="tool-btn active">erase)
    end

    test "the eraser marks only itself" do
      html = toolbar(%{tool: @eraser})
      assert [[_, "erase"]] = active(html)
    end
  end

  describe "controls and shortcuts" do
    test "the game offers every control and names every shortcut; the board has no undo" do
      game = game_toolbar(@brush)
      assert game =~ ">undo</button>"
      assert attr(toolbar_tag(game), "data-draw-shortcuts") == "undo brush eraser size"

      assert game =~
               ~s(<span class="mono toolbar-hint"><span class="kbd">⌘/Ctrl+Z</span> undo · <span class="kbd">B</span> brush · <span class="kbd">E</span> eraser · <span class="kbd">[</span><span class="kbd">]</span> size</span>)

      board = board(@brush)
      refute board =~ "undo"
      assert attr(toolbar_tag(board), "data-draw-shortcuts") == "brush eraser size"

      assert board =~
               ~s(<span class="mono toolbar-hint"><span class="kbd">B</span> brush · <span class="kbd">E</span> eraser · <span class="kbd">[</span><span class="kbd">]</span> size</span>)
    end

    test "without shortcuts the toolbar names none and shows no hint" do
      html = toolbar(%{tool: @brush})
      assert toolbar_tag(html) == ~s(<div class="toolbar">)
      refute html =~ "kbd"
    end

    test "a surface shows only the controls it turns on" do
      html = toolbar(%{tool: @brush, controls: [:sizes, :clear]})
      refute html =~ "swatch"
      assert [_] = sliders(html)
      assert html =~ ">clear</button>"
      refute html =~ ">erase</button>"
      refute html =~ ">undo</button>"

      assert toolbar(%{tool: @brush, controls: []}) =~ ~r/<div class="toolbar">\s*<\/div>/
    end

    test "a shortcut is live, and named, only with its control" do
      html = toolbar(%{tool: @brush, controls: [:colors, :undo], shortcuts: true})
      assert attr(toolbar_tag(html), "data-draw-shortcuts") == "undo"
      assert html =~ "⌘/Ctrl+Z"
      refute html =~ ~s(<span class="kbd">E</span>)
      refute html =~ ~s(<span class="kbd">B</span>)

      # B comes with the eraser: the way back to the brush from the keyboard.
      html = toolbar(%{tool: @brush, controls: [:eraser], shortcuts: true})
      assert attr(toolbar_tag(html), "data-draw-shortcuts") == "brush eraser"
      refute html =~ "⌘/Ctrl+Z"

      assert html =~
               ~s(<span class="kbd">B</span> brush · <span class="kbd">E</span> eraser</span>)

      html = toolbar(%{tool: @brush, controls: [:sizes], shortcuts: true})
      assert attr(toolbar_tag(html), "data-draw-shortcuts") == "size"

      html = toolbar(%{tool: @brush, controls: [:colors, :clear], shortcuts: true})
      assert toolbar_tag(html) == ~s(<div class="toolbar">)
      refute html =~ "kbd"
    end

    test "the names are the controls draw_controls.mjs knows" do
      js = File.read!(Path.join(@root, "lib/scrawly_web/pages/draw_controls.mjs"))

      for name <- String.split(DrawingToolbar.shortcut_names(DrawingToolbar.controls())) do
        assert js =~ ~s(control: "#{name}"), name
      end

      assert DrawingToolbar.shortcut_names([:colors, :clear]) == nil
    end
  end

  describe "the tool model" do
    test "a colour picks the brush; a size keeps the tool; the eraser toggles; B is the brush" do
      assert DrawingToolbar.select_color(@eraser, "#d63838") == %{@brush | color: "#d63838"}
      assert DrawingToolbar.select_size(@eraser, 20) == %{@eraser | size: 20}
      assert DrawingToolbar.select_size(@brush, 20) == %{@brush | size: 20}
      assert DrawingToolbar.toggle_eraser(@brush) == @eraser
      assert DrawingToolbar.toggle_eraser(@eraser) == @brush
      # Colour and size kept; already the brush, nothing changes.
      assert DrawingToolbar.select_brush(@eraser) == @brush
      assert DrawingToolbar.select_brush(@brush) == @brush
    end

    test "the size is clamped to 1..40; anything but a whole number changes nothing" do
      for {size, clamped} <- [{0, 1}, {-3, 1}, {1, 1}, {40, 40}, {41, 40}, {1000, 40}] do
        assert DrawingToolbar.select_size(@eraser, size) == %{@eraser | size: clamped}
      end

      for size <- [nil, 2.5, "5", :big] do
        assert DrawingToolbar.select_size(@eraser, size) == @eraser
      end
    end

    test "anything but a #rrggbb colour changes nothing" do
      for color <- [nil, 3, "red", "#fff", :black] do
        assert DrawingToolbar.select_color(@eraser, color) == @eraser
      end
    end

    test "a :select_size event's size: `size`, or the slider's value" do
      assert DrawingToolbar.size_param(%{size: 12}) == 12
      assert DrawingToolbar.size_param(%{event: %{value: "12"}}) == 12
      assert DrawingToolbar.size_param(%{event: %{value: "40"}}) == 40

      for params <- [%{}, %{event: %{value: "x"}}, %{event: %{value: "1.5"}}, %{event: %{}}] do
        assert DrawingToolbar.size_param(params) == nil
      end
    end

    test "JS gets the tool's name as a string" do
      assert DrawingToolbar.js_tool(@eraser) == %{tool: "eraser", color: "#2a6df4", size: 10}
    end
  end

  describe "the pages' tool actions" do
    test "the home board's toolbar changes its tool and pushes it" do
      component = %Component{state: %{draw_tool: DrawingToolbar.default_tool()}}

      {red, calls} =
        js_calls(fn -> HomePage.action(:select_color, %{color: "#d63838"}, component) end)

      assert red.state.draw_tool == %{tool: :brush, color: "#d63838", size: 4}
      assert calls == [{:setDrawTool, [%{tool: "brush", color: "#d63838", size: 4}]}]

      {erasing, calls} = js_calls(fn -> HomePage.action(:toggle_eraser, %{}, red) end)
      assert erasing.state.draw_tool.tool == :eraser
      assert calls == [{:setDrawTool, [%{tool: "eraser", color: "#d63838", size: 4}]}]

      # The slider while erasing: the eraser at the new size.
      {big, calls} =
        js_calls(fn -> HomePage.action(:select_size, %{event: %{value: "20"}}, erasing) end)

      assert big.state.draw_tool == %{tool: :eraser, color: "#d63838", size: 20}
      assert calls == [{:setDrawTool, [%{tool: "eraser", color: "#d63838", size: 20}]}]

      {cleared, calls} = js_calls(fn -> HomePage.action(:clear_canvas, %{}, big) end)
      assert cleared == big
      assert calls == [{:clearBoard, []}]
    end

    test "the home page pushes its tool before it connects the board" do
      component = %Component{state: %{draw_tool: @eraser}}
      {_result, calls} = js_calls(fn -> HomePage.action(:connect_lobby, %{}, component) end)

      assert calls == [
               {:setDrawTool, [%{tool: "eraser", color: "#2a6df4", size: 10}]},
               {:connectDemoBoard, []}
             ]
    end

    test "the game's and the board's actions do the same to the tool" do
      for {name, params} <- [
            select_color: %{color: "#1f9a4a"},
            select_size: %{size: 5},
            select_size: %{event: %{value: "33"}},
            select_size: %{event: %{value: "99"}},
            toggle_eraser: %{},
            select_brush: %{}
          ],
          tool <- [@brush, @eraser] do
        game = GamePage.action(name, params, %Component{state: %{draw_tool: tool}})
        home = HomePage.action(name, params, %Component{state: %{draw_tool: tool}})
        assert game.state.draw_tool == home.state.draw_tool, "#{name} from #{inspect(tool)}"
      end
    end
  end

  describe "one coordinate system" do
    test "the game canvas and the home board are both 800 x 450" do
      for html <- [canvas(), board(@brush)] do
        assert html =~ ~s(viewBox="0 0 800 450")
        assert html =~ ~s(preserveAspectRatio="xMidYMid meet")
      end
    end

    test "the active paths carry no style of their own: JS sets the tool's on each stroke" do
      [drawing] = Regex.run(~r/<path id="drawing-path"[^>]*>/, canvas())
      [demo] = Regex.run(~r/<path id="demo-board-active-path"[^>]*>/, board(@brush))

      for path <- [drawing, demo] do
        refute path =~ "stroke="
        refute path =~ "stroke-width="
      end
    end
  end

  describe "the size ring" do
    test "each canvas has one, beside its svg (not among the strokes), with two circles" do
      for {html, svg_id, ring_id} <- [
            {canvas(), "game-canvas-svg", "game-canvas-ring"},
            {board(@brush), "demo-board-svg", "demo-board-ring"}
          ] do
        # The canvas svg closes before the ring opens: the ring is a sibling.
        [canvas_svg] = Regex.run(~r/<svg[^>]*id="#{svg_id}".*?<\/svg>/s, html)
        refute canvas_svg =~ ring_id

        assert html =~
                 ~r/<svg id="#{ring_id}" class="size-ring" aria-hidden="true" focusable="false">\s*<circle class="size-ring-outer"><\/circle>\s*<circle class="size-ring-inner"><\/circle>\s*<\/svg>/
      end
    end

    test "the ring sits on its own layer, hidden until JS shows it, and lets pointers through" do
      css = File.read!(Path.join(@root, "assets/css/app.css"))
      [rule] = Regex.run(~r/\.demo-canvas \.size-ring \{([^}]*)\}/, css, capture: :all_but_first)

      for decl <- [
            "will-change: transform",
            "visibility: hidden",
            "pointer-events: none",
            "position: absolute"
          ] do
        assert rule =~ decl
      end

      # The frames clip it and keep its z-index inside.
      for frame <- [".canvas-frame", ".demo-canvas"] do
        [body] = Regex.run(~r/\n#{Regex.escape(frame)} \{([^}]*)\}/, css, capture: :all_but_first)
        assert body =~ "overflow: hidden"
        assert body =~ "isolation: isolate"
      end
    end
  end
end
