defmodule ScrawlyWeb.Components.RoomSettingsFormTest do
  @moduledoc """
  The create-room form (create-room-form): its values, what it sends its
  parent, what it shows (labels, the example line, the hints, the server's
  errors, "creating…"), and that every default is playable.
  """
  # js_calls/1 traces Hologram.JS.call/4 globally.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Scrawly.JsCallTrace, only: [js_calls: 1]

  alias Hologram.Component
  alias Hologram.Component.Action
  alias Hologram.Template.Renderer
  alias ScrawlyWeb.Components.RoomSettingsForm
  alias ScrawlyWeb.RoomSettings

  @props %{
    cid: "create-room-1",
    initial: %{},
    on_submit: :create_room,
    on_cancel: :hide_create_room,
    parent_cid: "page",
    busy: false,
    min_players: 2,
    errors: %{},
    title: "new room",
    subtitle: "ready to play as it is. change what you like.",
    submit_label: "create room",
    busy_label: "creating…",
    name_placeholder: "TESTu's room"
  }

  defp form(props \\ %{}) do
    props = Map.merge(@props, props)
    RoomSettingsForm.init(props, %Component{props: props})
  end

  defp with_values(component, values),
    do: %{
      component
      | state: %{component.state | values: Map.merge(component.state.values, values)}
    }

  defp render(component) do
    {html, _registry, _server} =
      RoomSettingsForm.template().(Map.merge(component.props, component.state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  defp submit(component), do: RoomSettingsForm.action(:submit, %{event: %{}}, component)

  describe "init" do
    test "starts from the defaults and focuses the name field" do
      component = form()

      assert component.state.values == RoomSettings.defaults()

      assert component.state.values == %{
               name: "",
               answer_kind: "mixed",
               word_source: "local",
               themes: [],
               prompt: "",
               ai_tone: "fun",
               round_duration: "60",
               round_multiplier: "1",
               max_players: "8"
             }

      assert component.next_action == %Action{name: :focus_name, params: %{}}

      {_result, calls} = js_calls(fn -> RoomSettingsForm.action(:focus_name, %{}, component) end)
      assert calls == [{:focusField, ["create-room-1-name"]}]
    end

    test "a parent can prefill it with a room's own values (atoms, integers)" do
      room = %{
        name: "TEST lobby",
        answer_kind: :phrases,
        word_source: :ai,
        prompt: "ocean animals",
        ai_tone: :weird,
        round_duration: 120,
        round_multiplier: 3,
        max_players: 6,
        code: "ABCDEF",
        status: :lobby
      }

      assert form(%{initial: room}).state.values == %{
               name: "TEST lobby",
               answer_kind: "phrases",
               word_source: "ai",
               themes: [],
               prompt: "ocean animals",
               ai_tone: "weird",
               round_duration: "120",
               round_multiplier: "3",
               max_players: "6"
             }

      assert form(%{initial: %{prompt: nil, max_players: 4}}).state.values.prompt == ""

      component =
        RoomSettingsForm.init(Map.put(@props, :initial, room), %Component{}, %Hologram.Server{})

      assert component.state.values.answer_kind == "phrases"
    end

    test "no state key shadows a prop" do
      component = form()
      assert MapSet.disjoint?(MapSet.new(Map.keys(component.state)), MapSet.new(Map.keys(@props)))
    end
  end

  describe "editing" do
    test "fields and seg buttons put their values" do
      component =
        form()
        |> then(
          &RoomSettingsForm.action(:put_value, %{field: :name, event: %{value: "TEST x"}}, &1)
        )
        |> then(&RoomSettingsForm.action(:put_value, %{field: :answer_kind, value: "words"}, &1))
        |> then(&RoomSettingsForm.action(:put_value, %{field: :round_duration, value: "300"}, &1))
        |> then(&RoomSettingsForm.action(:put_value, %{field: :round_multiplier, value: "5"}, &1))
        |> then(
          &RoomSettingsForm.action(:put_value, %{field: :max_players, event: %{value: "12"}}, &1)
        )

      assert %{
               name: "TEST x",
               answer_kind: "words",
               round_duration: "300",
               round_multiplier: "5",
               max_players: "12"
             } = component.state.values
    end

    test "unknown fields and non-string values change nothing" do
      component = form()

      for params <- [
            %{field: :creator_id, value: "x"},
            %{field: "name", value: "x"},
            %{field: :name, value: 7},
            %{field: :name, event: %{value: nil}}
          ] do
        assert RoomSettingsForm.action(:put_value, params, component) == component
      end
    end

    test "a theme chip turns on and off; put_value can't set the themes" do
      component =
        form()
        |> then(&RoomSettingsForm.action(:put_value, %{field: :word_source, value: "themes"}, &1))
        |> then(&RoomSettingsForm.action(:toggle_theme, %{theme: "sports"}, &1))
        |> then(&RoomSettingsForm.action(:toggle_theme, %{theme: "animals"}, &1))
        |> then(&RoomSettingsForm.action(:toggle_theme, %{theme: "Elixir.Kernel"}, &1))

      assert {component.state.values.word_source, component.state.values.themes} ==
               {"themes", ["animals", "sports"]}

      off = RoomSettingsForm.action(:toggle_theme, %{theme: "animals"}, component)
      assert off.state.values.themes == ["sports"]

      assert RoomSettingsForm.action(:put_value, %{field: :themes, value: "food"}, component) ==
               component
    end

    test "a room with themes opens on them" do
      component = form(%{initial: %{word_source: :local, themes: [:food, :animals]}})

      assert {component.state.values.word_source, component.state.values.themes} ==
               {"themes", ["animals", "food"]}
    end

    test "picking your own theme moves the focus to the theme field" do
      {component, calls} =
        js_calls(fn ->
          RoomSettingsForm.action(:put_value, %{field: :word_source, value: "ai"}, form())
        end)

      assert component.state.values.word_source == "ai"
      assert calls == [{:focusField, ["create-room-1-theme"]}]
    end
  end

  describe "submit" do
    test "sends the values to the parent's action" do
      component = form() |> with_values(%{name: "TEST room", answer_kind: "words"})

      assert submit(component).next_action == %Action{
               name: :create_room,
               target: "page",
               params: %{values: component.state.values},
               delay: 0
             }
    end

    test "the defaults are submittable as they are" do
      assert %Action{name: :create_room, params: %{values: values}} = submit(form()).next_action
      assert values == RoomSettings.defaults()
    end

    test "goes to the parent_cid and on_submit the parent chose" do
      component = form(%{on_submit: :save_settings, parent_cid: "page-settings"})

      assert %Action{name: :save_settings, target: "page-settings"} =
               submit(component).next_action
    end

    test "your own theme without a theme isn't sent" do
      for prompt <- ["", "   "] do
        component = form() |> with_values(%{word_source: "ai", prompt: prompt})
        assert submit(component) == component
      end

      component = form() |> with_values(%{word_source: "ai", prompt: "ocean animals"})
      assert %Action{name: :create_room} = submit(component).next_action
    end

    test "themes with no chip on aren't sent; with one, the chips go with the values" do
      component = form() |> with_values(%{word_source: "themes"})
      assert submit(component) == component

      component = with_values(component, %{themes: ["food"]})

      assert %Action{params: %{values: %{word_source: "themes", themes: ["food"]}}} =
               submit(component).next_action
    end

    test "nothing is sent again while the parent's command runs" do
      component = form(%{busy: true})
      assert submit(component) == component
    end
  end

  describe "template" do
    test "the fields, in order, with the form's wording" do
      html = render(form())

      labels =
        ~r/class="field-label"[^>]*>([^<]+)</
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      assert labels == ["name", "answers", "topic", "draw time", "turns each", "players"]

      for text <- [
            "everything",
            "your own theme",
            "60 s",
            "2 min",
            "5 min",
            "everyone draws once",
            "up to 2",
            "up to 12",
            "TESTu&#39;s room",
            ">cancel<"
          ] do
        assert html =~ text
      end

      assert html =~ ~r/type="submit"[^>]*>\s*create room\s*</

      for jargon <- ["local", "words / round", "rounds / player", "word source", "×"] do
        refute html =~ jargon
      end

      assert html =~ ~s(id="create-room-1-name")
      assert html =~ ~s(maxlength="40")
      refute html =~ "disabled"
    end

    test "the example line follows the answers choice" do
      examples =
        for kind <- ["words", "phrases", "mixed"] do
          html = render(form() |> with_values(%{answer_kind: kind}))
          [example] = Regex.run(~r/e\.g\. ([^<]+)</, html, capture: :all_but_first)
          example
        end

      assert examples == [
               "frog · bicycle · castle",
               "polar bear · jack in the box · traffic light",
               "frog · polar bear · castle"
             ]
    end

    test "your own theme: a theme field and a style; empty, the button is off and the form says why" do
      empty = render(form() |> with_values(%{word_source: "ai"}))

      assert empty =~ ~s(id="create-room-1-theme")
      assert empty =~ "ocean animals, things in a kitchen…"
      assert empty =~ ">style<"
      assert empty =~ "weird"
      assert empty =~ "type a theme to create the room, or pick everything."
      assert empty =~ ~r/<button[^>]*type="submit"[^>]*disabled/

      typed = render(form() |> with_values(%{word_source: "ai", prompt: "ocean animals"}))
      refute typed =~ "type a theme"
      assert typed =~ "AI picks the words for your theme when the game starts."
      refute typed =~ ~r/<button[^>]*type="submit"[^>]*disabled/
    end

    test "themes: the ten chips, those on pressed; none on, the button is off and the form says why" do
      plain = render(form())
      refute plain =~ "theme-chip"

      none = render(form() |> with_values(%{word_source: "themes"}))

      chips =
        ~r/<button type="button" class="(theme-chip[^"]*)" aria-pressed="(true|false)">(\w+)<\/button>/
        |> Regex.scan(none, capture: :all_but_first)

      assert Enum.map(chips, &List.last/1) == RoomSettings.theme_options()

      assert Enum.all?(chips, fn [class, pressed, _name] ->
               {class, pressed} == {"theme-chip", "false"}
             end)

      assert none =~ "pick at least one theme, or pick everything."
      assert none =~ ~r/<button[^>]*type="submit"[^>]*disabled/

      some = render(form() |> with_values(%{word_source: "themes", themes: ["animals", "food"]}))

      assert some =~
               ~s(<button type="button" class="theme-chip active" aria-pressed="true">animals</button>)

      assert some =~
               ~s(<button type="button" class="theme-chip active" aria-pressed="true">food</button>)

      assert some =~
               ~s(<button type="button" class="theme-chip" aria-pressed="false">objects</button>)

      assert some =~ "the choices come from these themes."
      refute some =~ "pick at least one theme"
      refute some =~ ~r/<button[^>]*type="submit"[^>]*disabled/

      # Your own theme shows no chips, even with some left in the values.
      ai = render(form() |> with_values(%{word_source: "ai", prompt: "x", themes: ["food"]}))
      refute ai =~ "theme-chip"
    end

    test "the turns hint counts the turns" do
      hints =
        for turns <- ["1", "2", "3", "5"] do
          render(form() |> with_values(%{round_multiplier: turns}))
        end

      assert Enum.at(hints, 0) =~ "everyone draws once"
      assert Enum.at(hints, 1) =~ "everyone draws twice"
      assert Enum.at(hints, 2) =~ "everyone draws 3 times"
      assert Enum.at(hints, 3) =~ "everyone draws 5 times"
    end

    test "busy: the button reads creating… and is off" do
      html = render(form(%{busy: true}))
      assert html =~ ~r/<button[^>]*type="submit"[^>]*disabled[^>]*>\s*creating…/
      refute html =~ "create room"
    end

    test "the server's errors: next to their field, or above the buttons" do
      html =
        render(
          form(%{errors: %{name: "use a name of at most 40 characters"}})
          |> with_values(%{name: "TEST kept"})
        )

      assert html =~
               ~r/id="create-room-1-name"[^>]*value="TEST kept"|value="TEST kept"[^>]*id="create-room-1-name"/

      assert html =~ ~s(<div class="field-error">use a name of at most 40 characters</div>)
      refute html =~ "app-modal-error"

      html = render(form(%{errors: %{form: "couldn't create the room, try again"}}))
      assert html =~ ~s(role="alert">couldn&#39;t create the room, try again</div>)

      html = render(form(%{errors: %{max_players: "pick 2 to 12 players"}}))
      assert html =~ ~s(<div class="field-error">pick 2 to 12 players</div>)

      html =
        render(
          form(%{errors: %{prompt: "type a theme, or pick everything"}})
          |> with_values(%{word_source: "ai"})
        )

      assert html =~ ~s(<div class="field-error">type a theme, or pick everything</div>)
    end

    test "min_players: no limit below the players in the room, and it says why" do
      html = render(form(%{min_players: 4}))

      for n <- 2..3,
          do: assert(html =~ ~s(<option value="#{n}" disabled="true">up to #{n}</option>))

      for n <- 4..12, do: assert(html =~ ~s(<option value="#{n}">up to #{n}</option>))

      assert html =~
               ~s(<div class="field-hint">4 players are in the room, so pick 4 or more</div>)

      # The server's own refusal takes the hint's place.
      html =
        render(
          form(%{
            min_players: 4,
            errors: %{max_players: "5 players are in the room, so pick 5 or more"}
          })
        )

      assert html =~
               ~s(<div class="field-error">5 players are in the room, so pick 5 or more</div>)

      refute html =~ "4 players are in the room"

      # The default (creating a room): every option, no hint.
      html = render(form())
      refute html =~ "players are in the room"
      refute html =~ "disabled"
    end

    test "Escape, the close button and cancel go to the parent's on_cancel" do
      source = File.read!("lib/scrawly_web/components/room_settings_form.ex")

      assert source =~ ~s(<window $key_down.escape={action: @on_cancel, target: @parent_cid} />)

      assert length(Regex.scan(~r/\$click=\{action: @on_cancel, target: @parent_cid\}/, source)) ==
               2
    end
  end

  test "a forged command is denied" do
    server = RoomSettingsForm.command(:create_room, %{}, %Hologram.Server{})
    assert server.next_action.name == :command_denied
  end
end
