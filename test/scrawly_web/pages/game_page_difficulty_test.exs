defmodule ScrawlyWeb.Pages.GamePageDifficultyTest do
  @moduledoc """
  Word difficulty on the game and score pages (choice-difficulty):

    * the drawer's choice buttons carry a chip, "easy", "medium · +25%" or
      "hard · +50%" (none for an AI word), easy to hard;
    * nobody else's page holds a difficulty while the drawer chooses: not in
      the markup, not in the state Hologram serializes into the page;
    * once the word is chosen everyone sees its chip beside the blanks, and
      the round summary shows it with the answer;
    * the score page shows each round's chip, and still renders games saved
      before rounds had a difficulty.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Compiler.Encoder
  alias Hologram.Template.Renderer
  alias Scrawly.Games
  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.{GamePage, GameScorePage}

  @moduletag :capture_log

  @choices [{"zzyzx", :easy}, {"TESTquokka", :medium}, {"TESTfjord", :hard}]
  @labels ["easy", "medium · +25%", "hard · +50%"]
  @difficulty_atoms ~w(easy medium hard)

  setup do
    drawer = create_user()
    guesser = create_user()
    room = start_room(drawer)

    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(guesser)).next_action.name ==
             :room_resynced

    %{room: room, drawer: drawer, guesser: guesser}
  end

  defp start!(ctx, entries \\ @choices) do
    {:ok, _} =
      RoomServer.start_game(ctx.room.id, ctx.drawer.id, %{word_choices: choices(entries)})

    :ok
  end

  defp init_page(room, server) do
    {component, _server} =
      GamePage.init(%{room_id: room.id}, %Hologram.Component{props: %{room_id: room.id}}, server)

    %{component | next_action: nil}
  end

  defp render(module, component) do
    {html, _registry, _server} =
      module.template().(Map.merge(component.props, component.state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  defp render(component), do: render(GamePage, component)

  # The rendered markup, then the state as Hologram embeds it in the page.
  defp page_output(component), do: render(component) <> Encoder.encode_term!(component.state)

  defp chips(html) do
    ~r{<span class="chip[^"]*difficulty-chip">([^<]*)</span>}
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  # The labels of the choice buttons, in the order shown.
  defp choice_buttons(html) do
    ~r{<span class="choice-word">([^<]*)</span>\s*(?:<span class="chip[^"]*difficulty-chip">([^<]*)</span>)?}
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn
      [text] -> {text, nil}
      [text, ""] -> {text, nil}
      [text, label] -> {text, label}
    end)
  end

  describe "while the drawer chooses" do
    test "the drawer's buttons show each choice with its difficulty, easy to hard", ctx do
      start!(ctx)
      html = render(init_page(ctx.room, server_for(ctx.drawer)))

      assert choice_buttons(html) == [
               {"zzyzx", "easy"},
               {"TESTquokka", "medium · +25%"},
               {"TESTfjord", "hard · +50%"}
             ]
    end

    test "AI choices have no chip", ctx do
      start!(ctx, ["TESTseahorse", {"TESTquokka", :medium}, "TESTwhale"])
      html = render(init_page(ctx.room, server_for(ctx.drawer)))

      assert choice_buttons(html) == [
               {"TESTseahorse", nil},
               {"TESTquokka", "medium · +25%"},
               {"TESTwhale", nil}
             ]
    end

    test "no other page holds a difficulty", ctx do
      start!(ctx)
      watcher = create_user()
      GamePage.command(:join_as_watcher, %{room_id: ctx.room.id}, server_for(watcher))

      for server <- [server_for(ctx.guesser), server_for(watcher), anon_server()] do
        page = init_page(ctx.room, server)
        assert page.state.word_choices == [] and page.state.word_difficulty == nil

        output = page_output(page)
        assert chips(output) == []
        for label <- @labels -- ["easy"], do: refute(output =~ label)
        for atom <- @difficulty_atoms, do: refute(output =~ ~s{Type.atom("#{atom}")})
        for {text, _} <- @choices, do: refute(output =~ text)
      end
    end
  end

  describe "once the word is chosen" do
    test "everyone sees its chip beside the blanks", ctx do
      start!(ctx)
      {:ok, _} = RoomServer.choose_word(ctx.room.id, ctx.drawer.id, "TESTfjord")

      for user <- [ctx.drawer, ctx.guesser] do
        html = render(init_page(ctx.room, server_for(user)))
        assert [meta] = Regex.run(~r{<div class="word-meta">.*?</div>}s, html)
        assert chips(meta) == ["hard · +50%"]
      end
    end

    test "an AI word has no chip", ctx do
      start!(ctx, ["TESTseahorse"])
      {:ok, _} = RoomServer.choose_word(ctx.room.id, ctx.drawer.id, "TESTseahorse")

      assert chips(render(init_page(ctx.room, server_for(ctx.guesser)))) == []
    end

    test "the round summary shows it with the answer", ctx do
      start!(ctx)
      {:ok, _} = RoomServer.choose_word(ctx.room.id, ctx.drawer.id, "TESTquokka")
      expire_round!(ctx.room)

      html = render(init_page(ctx.room, server_for(ctx.guesser)))
      assert [head] = Regex.run(~r{<div class="round-summary-head mono">.*?</div>}s, html)
      assert head =~ "the answer was"
      assert chips(head) == ["medium · +25%"]
    end
  end

  describe "the score page" do
    test "shows each round's difficulty, and renders rounds saved without one", ctx do
      {:ok, game} = Games.create_game(ctx.room.id, 3)

      round = fn n, word, extra ->
        Map.merge(
          %{
            "round" => n,
            "word" => word,
            "drawer_name" => ctx.drawer.username,
            "drawer_points" => 0,
            "player_scores" => [],
            "drawing_strokes" => []
          },
          extra
        )
      end

      Games.save_round_details!(game, [
        round.(1, "TESTfjord", %{"difficulty" => "hard"}),
        # Saved before rounds had a difficulty.
        round.(2, "TESTlegacy", %{}),
        # An AI word, and a value that isn't a difficulty.
        round.(3, "TESTseahorse", %{"difficulty" => nil}),
        round.(4, "TESTforged", %{"difficulty" => "Elixir.Kernel"})
      ])

      {component, _server} =
        GameScorePage.init(%{game_id: game.id}, %Hologram.Component{}, server_for(ctx.guesser))

      assert Enum.map(component.state.round_details, &{&1.word, &1.difficulty}) == [
               {"TESTfjord", :hard},
               {"TESTlegacy", nil},
               {"TESTseahorse", nil},
               {"TESTforged", nil}
             ]

      html = render(GameScorePage, component)
      assert chips(html) == ["hard · +50%"]
      assert html =~ "TESTLEGACY"
    end
  end
end
