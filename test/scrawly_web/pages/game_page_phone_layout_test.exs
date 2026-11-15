defmodule ScrawlyWeb.Pages.GamePagePhoneLayoutTest do
  @moduledoc """
  The game page on a phone (play-phone-layout). Under 720 px the stylesheet
  reorders the desktop markup into one screen: a compact bar, the scores as a
  one-line strip, the canvas, the guess input, then the latest chat lines,
  newest first. These tests pin what that rests on:

    * the template keeps one copy of each part, for both a guesser and the
      drawer (the reordering is CSS only);
    * the strip opens the full list and closes it again (client actions, no
      command), and says so to assistive tech;
    * the canvas keeps `touch-action: none`, so a finger drawing never
      scrolls or zooms the page;
    * the phone rules in app.css: the screen sized with `100dvh`, the input
      before the chat lines, the lines newest first, a 16 px input (iOS
      zooms into smaller ones on focus), and every class they style still
      present in the markup; wider screens lay out as before.

  How it looks at 360, 390, 768 and 1440 px was checked in a browser (see
  the task's hand-off); a test can't measure layout.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Template.Renderer
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @root Path.expand("../../..", __DIR__)
  @css_path Path.join(@root, "assets/css/app.css")
  @markup_sources Enum.map(
                    ~w(pages/game_page.ex components/chat_box.ex components/score_board.ex
                       components/drawing_canvas.ex components/avatar.ex layouts/app_layout.ex),
                    &Path.join([@root, "lib/scrawly_web", &1])
                  )

  # Three players, so one correct guess doesn't end the round.
  setup do
    drawer = create_user()
    guesser = create_user()
    other = create_user()
    room = start_room(drawer)

    for user <- [guesser, other] do
      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
               :room_resynced
    end

    start_drawing!(room, drawer, "bowling alley")
    %{room: room, drawer: drawer, guesser: guesser, other: other}
  end

  defp init_page(room, user) do
    {component, _server} =
      GamePage.init(
        %{room_id: room.id},
        %Hologram.Component{props: %{room_id: room.id}},
        server_for(user)
      )

    %{component | next_action: nil}
  end

  defp render(component) do
    {html, _registry, _server} =
      GamePage.template().(Map.merge(component.props, component.state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  defp count(html, fragment), do: length(String.split(html, fragment)) - 1

  # The rules inside the "Play on phones" `@media (max-width: 720px)` block.
  defp phone_block do
    css = File.read!(@css_path)
    [_, after_title] = String.split(css, "/* ─── Play on phones", parts: 2)
    [_, from_media] = String.split(after_title, "@media (max-width: 720px) {", parts: 2)
    take_block(from_media, 1, "")
  end

  defp take_block(_rest, 0, acc), do: String.slice(acc, 0..-2//1)
  defp take_block("{" <> rest, depth, acc), do: take_block(rest, depth + 1, acc <> "{")
  defp take_block("}" <> rest, depth, acc), do: take_block(rest, depth - 1, acc <> "}")

  defp take_block(<<c::utf8, rest::binary>>, depth, acc),
    do: take_block(rest, depth, acc <> <<c::utf8>>)

  # The declarations of the first rule in `css` whose selector list is
  # exactly `selector`.
  defp declarations(css, selector) do
    pattern = ~r/(?:^|[}\n])\s*#{Regex.escape(selector)}\s*\{([^}]*)\}/

    case Regex.run(pattern, css, capture: :all_but_first) do
      [body] -> body
      nil -> flunk("no rule for #{selector}")
    end
  end

  # The stylesheet without any @media block: what wide screens get.
  defp outside_media do
    css = File.read!(@css_path)

    css
    |> String.split("@media")
    |> Enum.with_index()
    |> Enum.map_join(fn
      {part, 0} ->
        part

      {part, _i} ->
        [_, body] = String.split(part, "{", parts: 2)
        drop_block(body, 1)
    end)
  end

  defp drop_block(rest, 0), do: rest
  defp drop_block("{" <> rest, depth), do: drop_block(rest, depth + 1)
  defp drop_block("}" <> rest, depth), do: drop_block(rest, depth - 1)
  defp drop_block(<<_c::utf8, rest::binary>>, depth), do: drop_block(rest, depth)

  describe "one copy of each part" do
    test "a guesser's page has one scoreboard, one canvas and one guess input", ctx do
      html = render(init_page(ctx.room, ctx.guesser))

      assert count(html, ~s(class="game-screen")) == 1
      assert count(html, ~s(class="scoreboard")) == 1
      assert count(html, ~s(id="game-canvas-svg")) == 1
      assert count(html, ~s(class="chat-input")) == 1
      assert count(html, ~s(id="chat-messages")) == 1
      assert count(html, ~s(class="toolbar toolbar-viewer")) == 1
      assert count(html, ~s(class="scores-toggle")) == 1
    end

    test "the drawer's page has one of each too, and one set of tools", ctx do
      html = render(init_page(ctx.room, ctx.drawer))

      assert count(html, ~s(class="scoreboard")) == 1
      assert count(html, ~s(id="game-canvas-svg")) == 1
      assert count(html, ~s(class="chat-input")) == 1
      assert count(html, ~s(class="toolbar")) == 1
      assert count(html, ~s(class="swatches")) == 1
      refute html =~ "toolbar-viewer"
    end

    test "the leave button keeps its word, so it is named on a phone too", ctx do
      html = render(init_page(ctx.room, ctx.guesser))
      assert html =~ ~s(<span class="leave-label">leave</span>)
    end
  end

  describe "the score strip" do
    test "starts closed, and the toggle says it can show all the scores", ctx do
      page = init_page(ctx.room, ctx.guesser)
      assert page.state.show_all_scores == false

      html = render(page)
      assert html =~ ~s(class="panel scores-panel")
      refute html =~ "scores-panel open"
      assert html =~ ~s(aria-expanded="false")
      assert html =~ ~s(aria-controls="scores-sheet")
      assert html =~ "show all scores"
    end

    test "a tap opens the full list, the next tap closes it", ctx do
      page = init_page(ctx.room, ctx.guesser)

      opened = GamePage.action(:toggle_scores, %{}, page)
      assert opened.state.show_all_scores == true
      assert opened.next_command == nil
      assert opened.next_action == nil

      html = render(opened)
      assert html =~ ~s(class="panel scores-panel open")
      assert html =~ ~s(aria-expanded="true")
      assert html =~ "hide the scores"

      closed = GamePage.action(:toggle_scores, %{}, opened)
      assert closed.state.show_all_scores == false
      refute render(closed) =~ "scores-panel open"
    end

    test "a tap outside or Escape closes it, and closing a closed list is harmless", ctx do
      page = init_page(ctx.room, ctx.drawer)
      opened = GamePage.action(:toggle_scores, %{}, page)

      hidden = GamePage.action(:hide_scores, %{event: %{}}, opened)
      assert hidden.state.show_all_scores == false
      assert hidden.next_command == nil

      assert GamePage.action(:hide_scores, %{}, hidden).state.show_all_scores == false
    end

    test "the strip lists every player with their marks; the list is the same markup", ctx do
      assert {:ok, {:correct, _}} =
               Scrawly.Games.RoomServer.submit_message(
                 ctx.room.id,
                 ctx.guesser.id,
                 "bowling alley"
               )

      page = init_page(ctx.room, ctx.other)

      for state <- [page, GamePage.action(:toggle_scores, %{}, page)] do
        html = render(state)
        assert count(html, ~s(<div class="item)) == 3
        assert html =~ ctx.drawer.username
        assert html =~ ctx.guesser.username
        assert html =~ ~s(aria-label="drawing")
        assert html =~ ~s(aria-label="guessed it")
      end
    end

    test "an older page state without the flag toggles from closed" do
      component = %Hologram.Component{state: %{}}
      assert GamePage.action(:toggle_scores, %{}, component).state.show_all_scores == true
    end
  end

  describe "drawing never moves the page" do
    test "the canvas takes every touch itself, for the drawer and for viewers", ctx do
      for user <- [ctx.drawer, ctx.guesser] do
        html = render(init_page(ctx.room, user))
        assert [svg] = Regex.run(~r/<svg\s+id="game-canvas-svg"[^>]*>/, html)
        assert svg =~ "touch-action: none"
      end
    end
  end

  describe "the phone stylesheet" do
    test "the game fills the screen under the header, without the footer" do
      screen = declarations(phone_block(), ".game-screen")
      assert screen =~ "height: calc(100dvh - 56px)"
      assert screen =~ "height: calc(100vh - 56px)"
      assert phone_block() =~ "body:has(.game-screen) .app-footer { display: none; }"
    end

    test "the guess input comes right after the canvas, then notes, then lines newest first" do
      block = phone_block()
      assert declarations(block, ".chat-panel .chat-input") =~ "order: -2"
      assert declarations(block, ".chat-panel .chat-note") =~ "order: -1"
      assert declarations(block, ".chat-panel #chat-messages") =~ "flex-direction: column-reverse"
      assert declarations(block, ".chat-panel > .panel-head") =~ "display: none"
    end

    test "the guess input is 16 px, so iOS doesn't zoom into it on focus" do
      assert declarations(phone_block(), ".chat-panel .chat-input input") =~ "font-size: 16px"
    end

    test "the drawer's tools wrap, the colours on a row of their own" do
      block = phone_block()
      assert declarations(block, ".toolbar .swatches") =~ "flex: 1 1 100%"
      assert declarations(block, ".tool-btn") =~ "height: 32px"
    end

    test "overlays fit a 360 px screen" do
      block = phone_block()
      assert declarations(block, ".choice-modal") =~ "width: calc(100% - 24px)"
      assert declarations(block, ".choice-modal") =~ "padding: 20px 16px"
      assert declarations(block, ".round-summary") =~ "padding: 18px 16px 14px"
    end

    test "every class the phone rules style is in the page's markup" do
      markup = Enum.map_join(@markup_sources, "\n", &File.read!/1)

      classes =
        Regex.scan(~r/\.([a-z][a-z0-9_-]*)/, phone_block(), capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      assert "scores-toggle" in classes
      assert "chat-note" in classes

      for class <- classes do
        assert markup =~ class, "app.css styles .#{class} on phones, but no template uses it"
      end
    end

    test "wider screens lay out as before: the strip's wrapper and toggle don't count" do
      wide = outside_media()
      assert declarations(wide, ".scores-sheet") =~ "display: contents"
      assert declarations(wide, ".scores-toggle") =~ "display: none"
      assert declarations(wide, ".timer-bar") =~ "width: 80px"

      assert declarations(wide, ".canvas-head") =~
               "padding: 10px 14px; border-bottom: 1px solid var(--hairline)"

      refute wide =~ "column-reverse"
      refute wide =~ "game-screen"
      refute wide =~ ".scores-panel"
    end
  end
end
