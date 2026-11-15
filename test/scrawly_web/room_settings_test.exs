defmodule ScrawlyWeb.RoomSettingsTest do
  @moduledoc """
  The room settings' wording and parsing (`ScrawlyWeb.RoomSettings`), and
  that every screen uses the form's labels: the room list row on Home, the
  lobby's settings panel and the form say the same thing, and no template
  shows the old jargon ("local", "words / round", "rounds / player") or raw
  error text.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Component
  alias Hologram.Template.Renderer
  alias Scrawly.Games.{Room, WordList}
  alias ScrawlyWeb.Components.RoomList
  alias ScrawlyWeb.Pages.GamePage
  alias ScrawlyWeb.RoomSettings

  @moduletag :capture_log

  defp render(module, vars) do
    {html, _registry, _server} =
      module.template().(vars)
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  describe "labels" do
    test "a room's settings in one line" do
      assert RoomSettings.summary(%{answer_kind: :mixed, round_duration: 60, round_multiplier: 2}) ==
               "mixed · 60 s · 2 turns each"

      assert RoomSettings.summary(%{
               answer_kind: :words,
               round_duration: 120,
               round_multiplier: 1
             }) ==
               "words · 2 min · 1 turn each"

      assert RoomSettings.summary(%{
               answer_kind: :phrases,
               round_duration: 300,
               round_multiplier: 5
             }) ==
               "phrases · 5 min · 5 turns each"

      # Missing or odd values read as the Room's defaults; odd times in seconds.
      assert RoomSettings.summary(%{}) == "mixed · 60 s · 1 turn each"
      assert RoomSettings.draw_time_label(90) == "90 s"
      assert RoomSettings.draw_time_label(180) == "3 min"
    end

    test "the theme of a themed room only" do
      assert RoomSettings.theme(%{word_source: :ai, prompt: "ocean animals"}) == "ocean animals"
      assert RoomSettings.theme(%{word_source: :local, prompt: "ocean animals"}) == nil
      assert RoomSettings.theme(%{word_source: :ai, prompt: ""}) == nil
      assert RoomSettings.theme(%{word_source: :ai}) == nil
      assert RoomSettings.topic_label(:ai) == "your own theme"
      assert RoomSettings.topic_label(:local) == "everything"
    end

    test "the chosen themes: at most three by name, then how many more" do
      assert RoomSettings.themes_label([:animals]) == "animals"
      assert RoomSettings.themes_label([:food, :animals]) == "animals, food"
      assert RoomSettings.themes_label([:animals, :food, :sports]) == "animals, food, sports"

      assert RoomSettings.themes_label([:animals, :food, :objects, :sports, :fantasy]) ==
               "animals, food, objects +2"

      assert RoomSettings.themes_label(WordList.themes()) == "animals, food, objects +7"
      assert RoomSettings.themes_label(["food", "animals"]) == "animals, food"

      # None is everything: no label.
      for none <- [[], nil, [:bogus], "animals"],
          do: assert(RoomSettings.themes_label(none) == nil)

      assert RoomSettings.themes_list([:fantasy, :animals, :food, :objects, :sports]) ==
               "animals, food, objects, sports, fantasy"

      assert RoomSettings.themes_list([]) == nil

      assert RoomSettings.topic_label(:local, [:animals]) == "themes"
      assert RoomSettings.topic_label(:local, []) == "everything"
      assert RoomSettings.topic_label(:ai, [:animals]) == "your own theme"
    end

    test "the default name" do
      assert RoomSettings.default_name("TESTann") == "TESTann's room"
      assert RoomSettings.default_name(nil) == "new room"
    end

    test "the limits are the Room's" do
      constraints = &Ash.Resource.Info.attribute(Room, &1).constraints
      assert constraints.(:name)[:max_length] == RoomSettings.name_max()
      assert constraints.(:prompt)[:max_length] == RoomSettings.theme_max()
      assert constraints.(:max_players)[:min] == 2
      assert constraints.(:max_players)[:max] == 12
    end

    test "every option the form offers is a valid room setting" do
      user = create_user()

      for {kind, _} <- RoomSettings.answer_options(),
          {duration, _} <- RoomSettings.draw_time_options(),
          {turns, _} <- RoomSettings.turn_options() do
        values = %{RoomSettings.defaults() | answer_kind: kind, round_duration: duration}
        values = %{values | round_multiplier: turns}
        attrs = values |> RoomSettings.to_attrs("TESTu") |> Map.put(:creator_id, user.id)

        assert Ash.Changeset.for_create(Room, :create, attrs).valid?
      end

      for {players, _} <- RoomSettings.player_options(),
          {tone, _} <- RoomSettings.style_options() do
        values = %{
          RoomSettings.defaults()
          | max_players: players,
            word_source: "ai",
            prompt: "TEST theme",
            ai_tone: tone
        }

        attrs = values |> RoomSettings.to_attrs("TESTu") |> Map.put(:creator_id, user.id)
        assert Ash.Changeset.for_create(Room, :create, attrs).valid?
      end

      for theme <- RoomSettings.theme_options() do
        values = %{RoomSettings.defaults() | word_source: "themes", themes: [theme]}
        attrs = values |> RoomSettings.to_attrs("TESTu") |> Map.put(:creator_id, user.id)
        assert Ash.Changeset.for_create(Room, :create, attrs).valid?
      end
    end
  end

  describe "themes (the form's side)" do
    test "topic is everything, themes or your own theme; the chips are the word list's themes" do
      assert RoomSettings.topic_options() == [
               {"local", "everything"},
               {"themes", "themes"},
               {"ai", "your own theme"}
             ]

      assert RoomSettings.theme_options() == Enum.map(WordList.themes(), &Atom.to_string/1)
      assert RoomSettings.defaults().themes == []
    end

    test "a chip turns on or off, and the chips stay in their order" do
      assert RoomSettings.toggle_theme([], "food") == ["food"]
      assert RoomSettings.toggle_theme(["food"], "animals") == ["animals", "food"]
      assert RoomSettings.toggle_theme(["animals", "food"], "animals") == ["food"]
      assert RoomSettings.toggle_theme(["food"], "food") == []

      for forged <- ["Food", "Elixir.Kernel", :food, nil, 7, ["food"]] do
        assert RoomSettings.toggle_theme(["food"], forged) == ["food"]
      end

      # Whatever the list held, only known names come back.
      assert RoomSettings.toggle_theme(["bogus", :sports, 7], "animals") == ["animals", "sports"]
      assert RoomSettings.toggle_theme(nil, "animals") == ["animals"]
    end

    test "themes with no chip on can't be submitted; other topics don't need any" do
      defaults = RoomSettings.defaults()

      assert RoomSettings.missing_themes?(%{defaults | word_source: "themes"})
      assert RoomSettings.missing_themes?(%{defaults | word_source: "themes", themes: ["bogus"]})
      refute RoomSettings.missing_themes?(%{defaults | word_source: "themes", themes: ["food"]})
      refute RoomSettings.missing_themes?(defaults)
      refute RoomSettings.missing_themes?(%{defaults | word_source: "ai", prompt: "x"})
    end

    test "a room with themes opens on the themes topic, its chips on" do
      values =
        RoomSettings.form_values(%{word_source: :local, themes: [:sports, :animals, :bogus]})

      assert {values.word_source, values.themes} == {"themes", ["animals", "sports"]}

      values = RoomSettings.form_values(%{word_source: "local", themes: ["food"]})
      assert {values.word_source, values.themes} == {"themes", ["food"]}

      assert RoomSettings.form_values(%{word_source: :local, themes: []}).word_source == "local"
      assert RoomSettings.form_values(%{themes: "animals"}).themes == []

      values = RoomSettings.form_values(%{word_source: :ai, prompt: "TEST", themes: []})
      assert {values.word_source, values.themes} == {"ai", []}
    end
  end

  describe "same labels everywhere" do
    test "the room list row: the summary, and the theme of a themed room" do
      rooms = [
        %{
          room_id: "a",
          name: "TEST a",
          code: "AAAA",
          status: :lobby,
          max_players: 4,
          answer_kind: :mixed,
          word_source: :local,
          prompt: nil,
          round_duration: 60,
          round_multiplier: 2,
          players: []
        },
        %{
          room_id: "b",
          name: "TEST b",
          code: "BBBB",
          status: :lobby,
          max_players: 4,
          answer_kind: :phrases,
          word_source: :ai,
          prompt: "ocean animals",
          round_duration: 120,
          round_multiplier: 1,
          players: []
        }
      ]

      html = render(RoomList, %{rooms: rooms})

      assert html =~ "mixed · 60 s · 2 turns each"
      assert html =~ "phrases · 2 min · 1 turn each"
      assert html =~ ~s(<span class="room-theme">theme: ocean animals</span>)
      assert length(Regex.scan(~r/theme: /, html)) == 1

      for jargon <- ["local", "[ai]", "[phrases]", "60s ×", "1r"] do
        refute html =~ jargon
      end
    end

    test "the room list row and the lobby's panel: the chosen themes" do
      row = fn themes ->
        render(RoomList, %{
          rooms: [
            %{
              room_id: "c",
              name: "TEST c",
              code: "CCCC",
              status: :lobby,
              max_players: 4,
              answer_kind: :words,
              themes: themes,
              word_source: :local,
              prompt: nil,
              round_duration: 60,
              round_multiplier: 1,
              players: []
            }
          ]
        })
      end

      assert row.([:food, :animals]) =~
               ~s(<span class="room-themes" title="animals, food">themes: animals, food</span>)

      assert row.([:animals, :food, :objects, :sports, :fantasy]) =~
               ~s(title="animals, food, objects, sports, fantasy">themes: animals, food, objects +2</span>)

      refute row.([]) =~ "themes:"

      creator = create_user()
      room = start_room(creator, %{answer_kind: :phrases, themes: [:animals, :food, :sports]})

      {component, _server} =
        GamePage.init(%{room_id: room.id}, %Component{}, server_for(creator))

      html = render(GamePage, Map.put(component.state, :room_id, room.id))
      assert html =~ ~s(<div class="k">topic</div><div class="v">themes</div>)

      assert html =~
               ~r/<div class="k">themes<\/div>\s*<div class="v"[^>]*>animals, food, sports<\/div>/

      refute html =~ ~s(<div class="k">theme</div>)
    end

    test "the lobby's settings panel, from a real room" do
      creator = create_user()

      room =
        start_room(creator, %{
          answer_kind: :words,
          word_source: :ai,
          prompt: "TEST ocean animals",
          ai_tone: :weird,
          round_duration: 300,
          round_multiplier: 3
        })

      {component, _server} =
        GamePage.init(%{room_id: room.id}, %Component{}, server_for(creator))

      html = render(GamePage, Map.put(component.state, :room_id, room.id))

      [panel] =
        Regex.run(
          ~r/<div class="panel-head">\s*<span>settings<\/span>.*?<\/div>\s*<\/div>\s*<\/div>/s,
          html
        )

      for {k, v} <- [
            {"answers", "words"},
            {"draw time", "5 min"},
            {"turns each", "3"},
            {"topic", "your own theme"},
            {"theme", "TEST ocean animals"}
          ] do
        assert panel =~ ~r/<div class="k">#{k}<\/div>\s*<div class="v"[^>]*>#{v}<\/div>/
      end

      assert panel =~ "style: weird"

      for jargon <- ["local", "word source", "rounds / player", "duration", "prompt", "×"] do
        refute panel =~ jargon
      end

      plain = start_room(create_user())

      {component, _server} =
        GamePage.init(%{room_id: plain.id}, %Component{}, server_for(creator))

      html = render(GamePage, Map.put(component.state, :room_id, plain.id))
      assert html =~ ~s(<div class="k">topic</div><div class="v">everything</div>)
      refute html =~ ~s(<div class="k">theme</div>)
      refute html =~ "local"
    end

    test "no template shows the old jargon or raw error text" do
      templates =
        "lib/scrawly_web/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          ~r/~HOLO"""(.*?)"""/s
          |> Regex.scan(File.read!(path), capture: :all_but_first)
          |> Enum.map(fn [template] -> {path, template} end)
        end)

      assert length(templates) > 10

      for {path, template} <- templates,
          jargon <- [
            ~r/\blocal\b/,
            ~r/words \/ round/,
            ~r/rounds \/ player/,
            ~r/word source/,
            ~r/inspect\(/
          ] do
        refute template =~ jargon, "#{path} shows #{inspect(jargon)}"
      end
    end
  end

  describe "the players floor (the lobby's form)" do
    test "too_few_players?/2 and the line that says why" do
      assert RoomSettings.too_few_players?("2", 3)
      refute RoomSettings.too_few_players?("3", 3)
      refute RoomSettings.too_few_players?("12", 3)
      refute RoomSettings.too_few_players?("2", 2)
      assert RoomSettings.too_few_players?("junk", 2)
      refute RoomSettings.too_few_players?("2", nil)

      for {value, _label} <- RoomSettings.player_options() do
        refute RoomSettings.too_few_players?(value, 2)
      end

      assert RoomSettings.players_floor(3) == "3 players are in the room, so pick 3 or more"
      assert RoomSettings.players_floor(nil) == "pick 2 to 12 players"
    end
  end

  describe "failure/3 (server)" do
    test "a refused change of settings says so, not \"create\"" do
      error = Ash.Error.Invalid.exception(errors: [])
      assert RoomSettings.failure(error, %{}) == {nil, "couldn't create the room, try again"}

      assert RoomSettings.failure(error, %{}, :update) ==
               {nil, "couldn't save the settings, try again"}

      assert RoomSettings.failure(:boom, %{}, :update) ==
               {nil, "couldn't save the settings, try again"}
    end
  end

  describe "to_attrs/2 (server)" do
    test "parses the form's strings, defaults an empty name, drops a built-in room's theme" do
      assert RoomSettings.to_attrs(RoomSettings.defaults(), "TESTu") == %{
               name: "TESTu's room",
               max_players: 8,
               answer_kind: :mixed,
               themes: [],
               word_source: :local,
               round_duration: 60,
               round_multiplier: 1
             }

      assert %{word_source: :ai, prompt: "x", ai_tone: :weird} =
               RoomSettings.to_attrs(
                 %{RoomSettings.defaults() | word_source: "ai", prompt: "x", ai_tone: "weird"},
                 "TESTu"
               )

      assert %{name: "TEST kept"} = RoomSettings.to_attrs(%{name: "TEST kept"}, nil)
      assert %{name: "new room"} = RoomSettings.to_attrs(%{name: " "}, nil)
    end

    test "themes: the known ones, in the word list's order, only for the themes topic" do
      themed = %{RoomSettings.defaults() | word_source: "themes"}

      assert %{word_source: :local, themes: [:animals, :food]} =
               RoomSettings.to_attrs(%{themed | themes: ["food", "animals", "food"]}, "TESTu")

      # Forged values are dropped; nothing left is everything.
      forged = ["Elixir.Kernel", "ANIMALS", " food", 7, nil, %{}, ["animals"], :sports, "fantasy"]

      assert RoomSettings.to_attrs(%{themed | themes: forged}, "TESTu").themes == [
               :sports,
               :fantasy
             ]

      for nothing <- [[], ["bogus"], "animals", nil, %{animals: true}] do
        assert RoomSettings.to_attrs(%{themed | themes: nothing}, "TESTu").themes == []
      end

      assert RoomSettings.to_attrs(%{word_source: "themes"}, "TESTu").themes == []

      # Any other topic plays no themes, whatever the values hold.
      for word_source <- ["local", "ai", nil, "bogus"] do
        values = %{themed | word_source: word_source, prompt: "x", themes: ["animals"]}
        assert RoomSettings.to_attrs(values, "TESTu").themes == []
      end
    end
  end
end
