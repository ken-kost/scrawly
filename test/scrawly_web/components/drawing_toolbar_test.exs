defmodule ScrawlyWeb.Components.DrawingToolbarTest do
  @moduledoc """
  The drawing toolbar shared by the game (the drawer's tools) and the home
  page's board (draw-toolbar, brush-size, colors): one colour list (24
  presets, the colour chip, the saved colours, the colour panel), one size
  slider (1..40, one size for the brush and the eraser) and one tool model;
  the controls and shortcuts each surface turns on; the pages' tool
  actions, which push the tool to draw_tools.mjs; the two canvases' common
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
  # A preset (dark blue).
  @brush %{tool: :brush, color: "#2563eb", size: 10}
  # Not a preset.
  @custom %{tool: :brush, color: "#123456", size: 10}
  @eraser %{@brush | tool: :eraser}

  defp render_dom(node) do
    {html, _registry, _server} = Renderer.render_dom(node, %Renderer.Env{}, %Hologram.Server{})
    html
  end

  defp toolbar(props) do
    %{controls: DrawingToolbar.controls(), shortcuts: false, saved: [], panel: false}
    |> Map.merge(props)
    |> then(&DrawingToolbar.template().(&1))
    |> render_dom()
  end

  # The game's toolbar as GamePage renders it for the drawer.
  defp game_toolbar(tool), do: toolbar(%{tool: tool, shortcuts: true})

  defp board(tool, saved \\ []),
    do: render_dom(GameDemo.template().(%{tool: tool, saved: saved, panel: false}))

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

  defp names, do: Enum.map(DrawingToolbar.presets(), &elem(&1, 1))

  # A page action on GamePage and on HomePage, with the JS each would call.
  defp both(name, params, state) do
    for page <- [GamePage, HomePage] do
      js_calls(fn -> page.action(name, params, %Component{state: state}) end)
    end
  end

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

        assert html =~ ~s(<div class="swatches" role="group" aria-label="colours">)
        assert html =~ ">erase</button>"
        assert html =~ ">clear</button>"
      end
    end

    test "24 colours, sizes 1 to 40, the brush in the first colour at 4" do
      assert length(DrawingToolbar.colors()) == 24
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

      colors_js = File.read!(Path.join(@root, "lib/scrawly_web/pages/colors.mjs"))
      assert colors_js =~ "export const MAX_SAVED = #{DrawingToolbar.max_saved()};"
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
      assert html =~ ~s(class="swatch active" style="background: #2563eb;")
      refute html =~ ~s(class="tool-btn active">erase)
    end

    test "a colour that is no preset marks no swatch" do
      assert active(toolbar(%{tool: @custom})) == []
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
      assert DrawingToolbar.js_tool(@eraser) == %{tool: "eraser", color: "#2563eb", size: 10}
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

    test "the home page pushes its tool before it connects the board, then loads saved colours" do
      component = %Component{state: %{draw_tool: @eraser, saved_colors: []}}
      {result, calls} = js_calls(fn -> HomePage.action(:connect_lobby, %{}, component) end)

      assert calls == [
               {:setDrawTool, [%{tool: "eraser", color: "#2563eb", size: 10}]},
               {:connectDemoBoard, []},
               {:savedColors, []}
             ]

      # On the server JS.call returns :ok: the state keeps its (empty) list.
      assert result.state.saved_colors == []
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

  describe "colours" do
    test "24 presets in 2 rows of 12, darker over lighter, each valid, distinct and named" do
      presets = DrawingToolbar.presets()
      assert length(presets) == 24
      assert Enum.map(presets, &elem(&1, 0)) == DrawingToolbar.colors()
      assert Enum.all?(DrawingToolbar.colors(), &Scrawly.Games.StrokeRules.valid_color?/1)
      assert Enum.all?(DrawingToolbar.colors(), &(&1 == String.downcase(&1)))
      assert names() == Enum.uniq(names())

      {dark, light} = Enum.split(names(), 12)
      hues = ~w(red orange yellow green cyan blue purple pink)
      assert Enum.take(dark, 4) == ["black", "dark grey", "brown", "dark skin"]
      assert Enum.take(light, 4) == ["white", "light grey", "grey", "light skin"]
      assert Enum.drop(dark, 4) == Enum.map(hues, &("dark " <> &1))
      assert Enum.drop(light, 4) == Enum.map(hues, &("light " <> &1))

      # Each dark shade is darker than the light one under it.
      luma = fn "#" <> hex ->
        <<r::8, g::8, b::8>> = Base.decode16!(hex, case: :lower)
        0.2126 * r + 0.7152 * g + 0.0722 * b
      end

      for {d, l} <-
            Enum.zip(
              Enum.take(DrawingToolbar.colors(), 12),
              Enum.drop(DrawingToolbar.colors(), 12)
            ),
          d != "#6b3a1e" do
        assert luma.(d) < luma.(l), "#{d} over #{l}"
      end
    end

    test "every preset is a button named for screen readers; the grid is one Tab stop" do
      html = toolbar(%{tool: @custom})

      for {color, name} <- DrawingToolbar.presets() do
        assert html =~
                 ~s(class="swatch" style="background: #{color};" aria-label="#{name}" title="#{name}")
      end

      assert [[first]] =
               Regex.scan(~r/style="background: (#[0-9a-f]{6});"[^>]*tabindex="0"/, html,
                 capture: :all_but_first
               )

      assert first == hd(DrawingToolbar.colors())
      assert length(Regex.scan(~r/class="swatch[^"]*"[^>]*tabindex="-1"/, html)) == 23
      assert html =~ ~s(<div class="color-grid" data-swatch-grid>)
    end

    test "the chip shows the tool's colour, a preset or not, the eraser's too" do
      for tool <- [@custom, %{@custom | tool: :eraser}, @brush] do
        html = toolbar(%{tool: tool})

        assert html =~
                 ~s(aria-label="colour #{tool.color}, more colours")

        assert html =~ ~s(<span class="color-chip-dot" style="background: #{tool.color};"></span>)
      end
    end

    test "saved colours: a third row after the presets, each selectable and removable" do
      saved = ["#123456", "#abcdef"]
      html = toolbar(%{tool: @custom, saved: saved})

      assert swatches(html) == Enum.map(DrawingToolbar.colors() ++ saved, &[&1])

      for c <- saved do
        assert html =~
                 ~s(aria-label="my colour #{c}" title="#{c}" aria-keyshortcuts="Delete" tabindex="-1" data-saved-color="#{c}")

        assert html =~
                 ~s(<button type="button" class="saved-remove" tabindex="-1" aria-label="remove #{c}" data-color-forget="#{c}">×</button>)
      end

      # The tool's colour, saved: marked like a preset.
      assert [[_, ""]] = active(html)
      assert html =~ ~s(class="swatch active" style="background: #123456;")

      # None saved (the server never renders any): an empty row.
      assert toolbar(%{tool: @custom}) =~
               ~s(<div class="saved-colors" role="group" aria-label="my colours"></div>)

      # The board shows them too.
      assert swatches(board(@custom, saved)) == Enum.map(DrawingToolbar.colors() ++ saved, &[&1])
    end

    test "the panel: closed until the page opens it; Escape and a backdrop only while open" do
      closed = toolbar(%{tool: @custom})
      assert closed =~ ~s(<div class="color-control" data-color-control>)
      assert closed =~ ~s(aria-expanded="false")
      refute closed =~ "color-backdrop"

      opened = toolbar(%{tool: @custom, panel: true})
      assert opened =~ ~s(<div class="color-control open" data-color-control>)
      assert opened =~ ~s(aria-expanded="true")
      assert opened =~ ~s(<div class="color-backdrop"></div>)

      assert opened =~
               ~s(<div class="color-sheet" id="color-sheet" role="dialog" aria-label="colours">)

      source = File.read!(Path.join(@root, "lib/scrawly_web/components/drawing_toolbar.ex"))
      assert source =~ ~s|$click_outside={if @panel do :close_color_panel end}|
      assert source =~ ~s|{%if @panel}<window $key_down.escape="close_color_panel" />|
    end

    test "the panel's controls are color_picker.mjs's: an empty container, no state in markup" do
      for html <- [toolbar(%{tool: @custom, panel: true}), board(@custom)] do
        assert html =~
                 ~s(<div class="color-panel"><div class="color-pick" data-color-pick></div></div>)
      end

      # Its wheel's CSS size is the one the module falls back on.
      js = File.read!(Path.join(@root, "lib/scrawly_web/pages/color_picker.mjs"))
      css = File.read!(Path.join(@root, "assets/css/app.css"))
      [size] = Regex.run(~r/export const WHEEL_SIZE = (\d+);/, js, capture: :all_but_first)
      [rule] = Regex.run(~r/\n\.color-wheel \{([^}]*)\}/, css, capture: :all_but_first)
      assert rule =~ "width: #{size}px; height: #{size}px;"
    end

    test "a colour is any #rrggbb, in either case; anything else changes nothing" do
      for color <- ["#123456", "#ABCDEF", "#aBcDeF", "#000000", "#ffffff"] do
        assert DrawingToolbar.hex_color?(color)
        assert DrawingToolbar.select_color(@eraser, color) == %{@brush | color: color}
      end

      for color <- [
            "#12345",
            "#1234567",
            "123456",
            "#12345g",
            "#+12345",
            "#-12345",
            " #123456",
            "#",
            "",
            nil,
            3,
            :red
          ] do
        refute DrawingToolbar.hex_color?(color), inspect(color)
        assert DrawingToolbar.select_color(@eraser, color) == @eraser
      end
    end

    test "saved colours from JS: its #rrggbb entries, at most 12; nil for no list" do
      assert DrawingToolbar.saved_colors(["#123456", "junk", 7, nil, "#ABCDEF"]) == [
               "#123456",
               "#ABCDEF"
             ]

      many = for i <- 1..20, do: "#0000" <> String.pad_leading(Integer.to_string(i, 16), 2, "0")
      assert DrawingToolbar.saved_colors(many) == Enum.take(many, 12)
      assert DrawingToolbar.saved_colors([]) == []

      for value <- [:ok, nil, "#123456", %{}] do
        assert DrawingToolbar.saved_colors(value) == nil
      end
    end
  end

  describe "the pages' colour actions" do
    test "a colour from the panel's native controls changes the state without a push" do
      for {result, calls} <- both(:color_picked, %{color: "#123456"}, %{draw_tool: @eraser}) do
        assert result.state.draw_tool == %{@eraser | tool: :brush, color: "#123456"}
        assert calls == []
      end

      for {result, _calls} <- both(:color_picked, %{color: "red"}, %{draw_tool: @eraser}) do
        assert result.state.draw_tool == @eraser
      end
    end

    test "a preset or saved colour (no preset) is the brush in it, pushed" do
      for {result, calls} <- both(:select_color, %{color: "#123456"}, %{draw_tool: @eraser}) do
        assert result.state.draw_tool == %{@brush | color: "#123456"}
        assert calls == [{:setDrawTool, [%{tool: "brush", color: "#123456", size: 10}]}]
      end
    end

    test "the chip opens and closes the panel; Escape, a click outside and done close it" do
      for {opened, []} <- both(:toggle_color_panel, %{}, %{color_panel: false}) do
        assert opened.state.color_panel == true
        assert opened.next_command == nil
      end

      for {closed, []} <- both(:toggle_color_panel, %{}, %{color_panel: true}) do
        assert closed.state.color_panel == false
      end

      for state <- [%{color_panel: true}, %{color_panel: false}],
          {closed, []} <- both(:close_color_panel, %{event: %{}}, state) do
        assert closed.state.color_panel == false
      end

      # A state from before the flag opens it.
      for {opened, []} <- both(:toggle_color_panel, %{}, %{}) do
        assert opened.state.color_panel == true
      end
    end

    test "+ save and the removals put the list JS stored; anything else keeps the list" do
      state = %{saved_colors: ["#111111"]}

      for {result, []} <- both(:saved_colors, %{colors: ["#222222", "#111111"]}, state) do
        assert result.state.saved_colors == ["#222222", "#111111"]
      end

      for {result, []} <- both(:saved_colors, %{colors: []}, state) do
        assert result.state.saved_colors == []
      end

      for params <- [%{}, %{colors: "#222222"}],
          {result, []} <- both(:saved_colors, params, state) do
        assert result.state.saved_colors == ["#111111"]
      end
    end

    test "the client loads the saved colours JS returns" do
      component = %Component{state: %{draw_tool: @brush, saved_colors: []}}
      previous = Application.get_env(:hologram, :__server_pass_through__)

      try do
        # What JS.call returns in the browser: the stored list.
        Application.put_env(:hologram, :__server_pass_through__, ["#123456", "#abcdef"])

        assert HomePage.action(:connect_lobby, %{}, component).state.saved_colors == [
                 "#123456",
                 "#abcdef"
               ]
      after
        if previous == nil,
          do: Application.delete_env(:hologram, :__server_pass_through__),
          else: Application.put_env(:hologram, :__server_pass_through__, previous)
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
