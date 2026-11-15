defmodule ScrawlyWeb.KeyboardShortcutsTest do
  @moduledoc """
  The keyboard shortcuts and dismissal actions behind the templates'
  `<window $key_down...>` / `$click_outside` bindings (keyboard-and-dismissal),
  and the actions the drawing shortcuts dispatch (draw_controls.mjs).

  Key filters match a superset of modifiers and fire on auto-repeat, so the
  actions receive every Ctrl/Cmd/Alt variant and every repeat and must ignore
  the ones that aren't the plain shortcut. `JS.call` is a server-side no-op;
  `js_calls/1` traces it to see which JS functions an action would call.
  """
  use ExUnit.Case, async: false

  import Scrawly.JsCallTrace, only: [js_calls: 1]

  alias Hologram.Component
  alias Hologram.Server
  alias Scrawly.Accounts.User
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Components.RoomSettingsForm
  alias ScrawlyWeb.Pages.{GamePage, HomePage}

  # The payload Hologram builds for a keydown (KeyboardEvent.buildOperationParam).
  defp key(key, overrides \\ %{}) do
    Map.merge(
      %{
        alt_key: false,
        code: "Key" <> String.upcase(key),
        ctrl_key: false,
        key: key,
        meta_key: false,
        repeat: false,
        shift_key: false
      },
      overrides
    )
  end

  describe "HomePage :shortcut_new (N)" do
    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
    end

    # The real init state for a stashed identity (what LoadCurrentUser leaves).
    defp home(user) do
      server = %Server{
        session: %{},
        stash: %{current_user_id: user && user.id, current_user: user}
      }

      {component, _server} = HomePage.init(%{}, %Component{}, server)
      component
    end

    defp registered, do: %User{id: Ecto.UUID.generate(), username: "TESTreg", is_guest: false}
    defp guest, do: %User{id: Ecto.UUID.generate(), username: "guest-test", is_guest: true}

    test "a registered user gets the create-room modal" do
      result = HomePage.action(:shortcut_new, %{event: key("n")}, home(registered()))

      assert result.state.show_create_room == true
      assert result.state.show_login_modal == false
    end

    test "a guest gets the page's register / sign-in modal, not create-room" do
      result = HomePage.action(:shortcut_new, %{event: key("n")}, home(guest()))

      assert result.state.show_login_modal == true
      assert result.state.login_error == ""
      assert result.state.show_create_room == false
    end

    test "a logged-out visitor gets the page's register / sign-in modal" do
      result = HomePage.action(:shortcut_new, %{event: key("n")}, home(nil))

      assert result.state.show_login_modal == true
      assert result.state.show_create_room == false
    end

    test "Shift+N works like N" do
      result =
        HomePage.action(:shortcut_new, %{event: key("N", %{shift_key: true})}, home(registered()))

      assert result.state.show_create_room == true
    end

    test "Ctrl, Cmd or Alt+N does nothing" do
      component = home(registered())

      for mod <- [:ctrl_key, :meta_key, :alt_key] do
        event = key("n", %{mod => true})
        assert HomePage.action(:shortcut_new, %{event: event}, component) == component
      end
    end

    test "does nothing while any home modal is open" do
      base = home(registered())

      open_states = [
        %{show_create_room: true},
        %{show_login_modal: true},
        %{show_reset_modal: true},
        %{recovery_code: "AAAA-BBBB-CCCC-DDDD-EEEE"}
      ]

      for open <- open_states do
        component = %{base | state: Map.merge(base.state, open)}
        assert HomePage.action(:shortcut_new, %{event: key("n")}, component) == component
      end

      guest_with_login_open = home(guest())

      guest_with_login_open = %{
        guest_with_login_open
        | state: %{guest_with_login_open.state | show_login_modal: true, login_error: "nope"}
      }

      assert HomePage.action(:shortcut_new, %{event: key("n")}, guest_with_login_open) ==
               guest_with_login_open
    end

    test ":noop (the typing guards' target) changes nothing" do
      component = home(registered())
      assert HomePage.action(:noop, %{event: key("n")}, component) == component
    end

    test "the Escape bindings' actions close the home modals" do
      component = home(registered())
      open = %{component | state: %{component.state | show_create_room: true}}

      assert HomePage.action(:hide_create_room, %{event: key("Escape")}, open).state.show_create_room ==
               false

      open = %{component | state: %{component.state | show_login_modal: true}}

      assert HomePage.action(:hide_login, %{event: key("Escape")}, open).state.show_login_modal ==
               false

      open = %{component | state: %{component.state | show_reset_modal: true}}

      assert HomePage.action(:hide_reset, %{event: key("Escape")}, open).state.show_reset_modal ==
               false
    end
  end

  describe "drawing shortcuts" do
    # E, Ctrl+Z / Cmd+Z and [ / ] are handled by draw_controls.mjs: one
    # native keydown listener behind one typing guard, which dispatches the
    # toolbar's own actions (the size keys step the slider). The keys, their
    # modifiers and the guard are tested in test/js/draw_controls.test.mjs;
    # these are the pages' side.

    defp drawer(overrides \\ %{}) do
      state =
        Map.merge(
          %{
            draw_tool: %{tool: :brush, color: "#d63838", size: 5},
            is_drawer: true,
            new_message: "hello"
          },
          overrides
        )

      %Component{props: %{room_id: "test-room"}, state: state}
    end

    test "E's action (:toggle_eraser) toggles the eraser and pushes it" do
      {on, calls} = js_calls(fn -> GamePage.action(:toggle_eraser, %{}, drawer()) end)

      assert on.state.draw_tool == %{tool: :eraser, color: "#d63838", size: 5}
      assert calls == [{:setDrawTool, [%{tool: "eraser", color: "#d63838", size: 5}]}]

      {off, calls} = js_calls(fn -> GamePage.action(:toggle_eraser, %{}, on) end)

      assert off.state.draw_tool == %{tool: :brush, color: "#d63838", size: 5}
      assert calls == [{:setDrawTool, [%{tool: "brush", color: "#d63838", size: 5}]}]
    end

    test "Ctrl+Z's action (:undo_drawing) undoes the last stroke" do
      component = drawer()
      {result, calls} = js_calls(fn -> GamePage.action(:undo_drawing, %{}, component) end)

      assert result == component
      assert calls == [{:undoStroke, []}]
    end

    test "a size key's step reaches the page as the slider's :select_size, eraser kept" do
      component = drawer(%{draw_tool: %{tool: :eraser, color: "#d63838", size: 5}})

      {result, calls} =
        js_calls(fn -> GamePage.action(:select_size, %{event: %{value: "10"}}, component) end)

      assert result.state.draw_tool == %{tool: :eraser, color: "#d63838", size: 10}
      assert calls == [{:setDrawTool, [%{tool: "eraser", color: "#d63838", size: 10}]}]
    end

    test "no drawing shortcut is a <window> key binding: they all take the guarded path" do
      root = Path.expand("../..", __DIR__)
      toolbar = File.read!(Path.join(root, "lib/scrawly_web/components/drawing_toolbar.ex"))
      refute toolbar =~ "$key_down"
      assert toolbar =~ ~s|data-draw-shortcuts={if @shortcuts do shortcut_names(@controls) end}|

      for file <- ["game_page.ex", "home_page.ex"] do
        source = File.read!(Path.join(root, "lib/scrawly_web/pages/" <> file))
        refute source =~ "shortcut_eraser", file
        refute source =~ "shortcut_undo", file
      end
    end

    test "Escape in the chat input (:clear_message) clears the message" do
      assert GamePage.action(:clear_message, %{event: key("Escape")}, drawer()).state.new_message ==
               ""
    end
  end

  describe "AppLayout" do
    defp layout(overrides) do
      %Component{
        state: Map.merge(%{show_accent_picker: true, show_login_modal: false}, overrides)
      }
    end

    test ":close_accent_picker closes the popover and is idempotent" do
      closed = AppLayout.action(:close_accent_picker, %{event: key("Escape")}, layout(%{}))
      assert closed.state.show_accent_picker == false

      assert AppLayout.action(:close_accent_picker, %{}, closed).state.show_accent_picker == false
    end

    test ":toggle_accent_picker still opens and closes it" do
      opened = AppLayout.action(:toggle_accent_picker, %{}, layout(%{show_accent_picker: false}))
      assert opened.state.show_accent_picker == true

      assert AppLayout.action(:toggle_accent_picker, %{}, opened).state.show_accent_picker ==
               false
    end

    test ":noop (the layout forms' typing guards) changes nothing" do
      component = layout(%{show_login_modal: true})
      assert AppLayout.action(:noop, %{event: key("n")}, component) == component
    end
  end

  # Every `<form>` that can share the screen with HomePage's `<window>` N
  # binding must stop "n" first, or typing n in it opens a modal. HomePage
  # renders its own forms, the create-room form (RoomSettingsForm, whose
  # :noop is its own) and the layout's; no other page binds N.
  describe "typing guards" do
    for {module, path, guard} <- [
          {HomePage, "lib/scrawly_web/pages/home_page.ex",
           ~s($key_down.n.stop_propagation="noop")},
          {RoomSettingsForm, "lib/scrawly_web/components/room_settings_form.ex",
           ~s($key_down.n.stop_propagation="noop")},
          {AppLayout, "lib/scrawly_web/layouts/app_layout.ex",
           ~s($key_down.n.stop_propagation={action: :noop, target: "layout"})}
        ] do
      test "every form in #{inspect(module)} carries the N guard" do
        forms = Regex.scan(~r/<form\b[^>]*>/s, File.read!(unquote(path)))

        assert forms != []

        for [form] <- forms do
          assert String.contains?(form, unquote(guard)), "unguarded form: #{form}"
        end
      end
    end
  end
end
