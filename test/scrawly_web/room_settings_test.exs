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
  alias Scrawly.Games.Room
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
          ~r/<div class="panel-head">settings<\/div>.*?<\/div>\s*<\/div>\s*<\/div>/s,
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

  describe "to_attrs/2 (server)" do
    test "parses the form's strings, defaults an empty name, drops a built-in room's theme" do
      assert RoomSettings.to_attrs(RoomSettings.defaults(), "TESTu") == %{
               name: "TESTu's room",
               max_players: 8,
               answer_kind: :mixed,
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
  end
end
