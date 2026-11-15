defmodule ScrawlyWeb.Components.DrawingToolbarTest do
  @moduledoc """
  The drawing toolbar shared by the game (the drawer's tools) and the home
  page's board (draw-toolbar): one colour list, one size list and one tool
  model; the controls each surface turns on; the pages' tool actions, which
  push the tool to draw_tools.mjs; and the two canvases' common coordinates.

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

  defp swatches(html),
    do:
      Regex.scan(~r/class="swatch[^"]*" style="background: (#[0-9a-f]{6});"/, html,
        capture: :all_but_first
      )

  defp size_buttons(html),
    do: Regex.scan(~r/class="tool-btn[^"]*"[^>]*>\s*<span class="size-dot"/, html)

  # The active buttons, with their text.
  defp active(html),
    do: Regex.scan(~r/class="(?:swatch|tool-btn) active"[^>]*>\s*([^<]*?)\s*</, html)

  describe "one toolbar for both canvases" do
    test "the game and the board show the same colours and sizes" do
      game = game_toolbar(DrawingToolbar.default_tool())
      board = board(DrawingToolbar.default_tool())

      colors = Enum.map(DrawingToolbar.colors(), &[&1])
      assert swatches(game) == colors
      assert swatches(board) == colors

      assert length(size_buttons(game)) == length(DrawingToolbar.sizes())
      assert length(size_buttons(board)) == length(DrawingToolbar.sizes())

      for html <- [game, board] do
        assert html =~ ~s(<div class="toolbar">)
        assert html =~ ~s(<div class="swatches">)
        assert html =~ ">erase</button>"
        assert html =~ ">clear</button>"
      end
    end

    test "today's game values: 8 colours, sizes 2/5/10/20, the brush in the first colour at 2" do
      assert length(DrawingToolbar.colors()) == 8
      assert DrawingToolbar.colors() == Enum.uniq(DrawingToolbar.colors())
      assert Enum.all?(DrawingToolbar.colors(), &Scrawly.Games.StrokeRules.valid_color?/1)
      assert DrawingToolbar.sizes() == [2, 5, 10, 20]
      assert Enum.all?(DrawingToolbar.sizes(), &Scrawly.Games.StrokeRules.valid_width?/1)

      assert DrawingToolbar.default_tool() == %{
               tool: :brush,
               color: hd(DrawingToolbar.colors()),
               size: hd(DrawingToolbar.sizes())
             }
    end

    test "draw_tools.mjs falls back to the same default tool" do
      js = File.read!(Path.join(@root, "lib/scrawly_web/pages/draw_tools.mjs"))
      %{tool: tool, color: color, size: size} = DrawingToolbar.default_tool()

      assert js =~
               ~s|export const DEFAULT_TOOL = Object.freeze({ tool: "#{tool}", color: "#{color}", size: #{size} });|
    end

    test "the size dots grow with the size" do
      html = toolbar(%{tool: @brush})

      dots =
        Regex.scan(~r/class="size-dot" style="width: (\d+)px; height: \1px;"/, html,
          capture: :all_but_first
        )

      assert dots == [["4"], ["7"], ["10"], ["14"]]
    end
  end

  describe "the selected tool" do
    test "the brush marks its colour and its size" do
      html = toolbar(%{tool: @brush})
      assert [[_swatch, ""], [_size, ""]] = active(html)
      assert html =~ ~s(class="swatch active" style="background: #2a6df4;")
      refute html =~ ~s(class="tool-btn active">erase)
    end

    test "the eraser marks only itself" do
      html = toolbar(%{tool: @eraser})
      assert [[_, "erase"]] = active(html)
    end
  end

  describe "controls" do
    test "the game offers every control and its shortcuts; the board has no undo, no shortcuts" do
      game = game_toolbar(@brush)
      assert game =~ ">undo</button>"

      assert game =~
               ~s(<span class="kbd">⌘/Ctrl+Z</span> undo · <span class="kbd">E</span> eraser)

      board = board(@brush)
      refute board =~ "undo"
      refute board =~ ~s(class="kbd")
    end

    test "a surface shows only the controls it turns on" do
      html = toolbar(%{tool: @brush, controls: [:sizes, :clear]})
      refute html =~ "swatch"
      assert length(size_buttons(html)) == 4
      assert html =~ ">clear</button>"
      refute html =~ ">erase</button>"
      refute html =~ ">undo</button>"

      assert toolbar(%{tool: @brush, controls: []}) =~ ~r/<div class="toolbar">\s*<\/div>/
    end

    test "a shortcut is named only with its control" do
      html = toolbar(%{tool: @brush, controls: [:colors, :undo], shortcuts: true})
      assert html =~ "⌘/Ctrl+Z"
      refute html =~ ~s(<span class="kbd">E</span>)

      html = toolbar(%{tool: @brush, controls: [:eraser], shortcuts: true})
      refute html =~ "⌘/Ctrl+Z"
      assert html =~ ~s(<span class="kbd">E</span> eraser)
    end

    test "the shortcuts are bound on window only with their controls" do
      source = File.read!(Path.join(@root, "lib/scrawly_web/components/drawing_toolbar.ex"))

      assert source =~
               ~s({%if @shortcuts and :eraser in @controls}\n        <window $key_down.e="shortcut_eraser" />)

      assert source =~ ~s({%if @shortcuts and :undo in @controls}\n        <window\n)
    end
  end

  describe "the tool model" do
    test "a colour or a size picks the brush; the eraser toggles" do
      assert DrawingToolbar.select_color(@eraser, "#d63838") == %{@brush | color: "#d63838"}
      assert DrawingToolbar.select_size(@eraser, 20) == %{@brush | size: 20}
      assert DrawingToolbar.toggle_eraser(@brush) == @eraser
      assert DrawingToolbar.toggle_eraser(@eraser) == @brush
    end

    test "anything but a #rrggbb colour or a size in 1..40 changes nothing" do
      for color <- [nil, 3, "red", "#fff", :black] do
        assert DrawingToolbar.select_color(@eraser, color) == @eraser
      end

      for size <- [nil, 0, 41, 2.5, "5"] do
        assert DrawingToolbar.select_size(@eraser, size) == @eraser
      end

      assert DrawingToolbar.select_size(@brush, 1).size == 1
      assert DrawingToolbar.select_size(@brush, 40).size == 40
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

      assert red.state.draw_tool == %{tool: :brush, color: "#d63838", size: 2}
      assert calls == [{:setDrawTool, [%{tool: "brush", color: "#d63838", size: 2}]}]

      {big, calls} = js_calls(fn -> HomePage.action(:select_size, %{size: 20}, red) end)
      assert big.state.draw_tool == %{tool: :brush, color: "#d63838", size: 20}
      assert calls == [{:setDrawTool, [%{tool: "brush", color: "#d63838", size: 20}]}]

      {erasing, calls} = js_calls(fn -> HomePage.action(:toggle_eraser, %{}, big) end)
      assert erasing.state.draw_tool.tool == :eraser
      assert calls == [{:setDrawTool, [%{tool: "eraser", color: "#d63838", size: 20}]}]

      {cleared, calls} = js_calls(fn -> HomePage.action(:clear_canvas, %{}, erasing) end)
      assert cleared == erasing
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
            toggle_eraser: %{}
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
      canvas =
        render_dom(DrawingCanvas.template().(%{is_drawer: true, strokes: []}))

      for html <- [canvas, board(@brush)] do
        assert html =~ ~s(viewBox="0 0 800 450")
        assert html =~ ~s(preserveAspectRatio="xMidYMid meet")
      end
    end

    test "the active paths carry no style of their own: JS sets the tool's on each stroke" do
      canvas = render_dom(DrawingCanvas.template().(%{is_drawer: true, strokes: []}))
      [drawing] = Regex.run(~r/<path id="drawing-path"[^>]*>/, canvas)
      [demo] = Regex.run(~r/<path id="demo-board-active-path"[^>]*>/, board(@brush))

      for path <- [drawing, demo] do
        refute path =~ "stroke="
        refute path =~ "stroke-width="
      end
    end
  end
end
