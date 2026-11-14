defmodule ScrawlyWeb.KeyboardShortcutsTest do
  @moduledoc """
  The keyboard shortcuts and dismissal actions behind the templates'
  `<window $key_down...>` / `$click_outside` bindings (keyboard-and-dismissal).

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

      HomePage.init(%{}, %Component{}, server)
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

  describe "GamePage drawer shortcuts" do
    defp drawer(overrides \\ %{}) do
      state =
        Map.merge(
          %{
            draw_color: "#d63838",
            draw_width: 5,
            draw_eraser: false,
            is_drawer: true,
            new_message: "hello"
          },
          overrides
        )

      %Component{props: %{room_id: "test-room"}, state: state}
    end

    test "E toggles the eraser like the toolbar button" do
      {on, calls} =
        js_calls(fn -> GamePage.action(:shortcut_eraser, %{event: key("e")}, drawer()) end)

      assert on.state.draw_eraser == true
      assert calls == [{:setToolColor, ["#FFFFFF"]}, {:setToolWidth, [20]}]

      {off, calls} = js_calls(fn -> GamePage.action(:shortcut_eraser, %{event: key("e")}, on) end)

      assert off.state.draw_eraser == false
      assert calls == [{:setToolColor, ["#d63838"]}, {:setToolWidth, [5]}]

      {toolbar, toolbar_calls} =
        js_calls(fn -> GamePage.action(:toggle_eraser, %{}, drawer()) end)

      assert toolbar.state == on.state
      assert toolbar_calls == [{:setToolColor, ["#FFFFFF"]}, {:setToolWidth, [20]}]
    end

    test "Shift+E toggles too" do
      result = GamePage.action(:shortcut_eraser, %{event: key("E", %{shift_key: true})}, drawer())
      assert result.state.draw_eraser == true
    end

    test "a held E (auto-repeat) toggles nothing after the first press" do
      component = drawer()

      {result, calls} =
        js_calls(fn ->
          GamePage.action(:shortcut_eraser, %{event: key("e", %{repeat: true})}, component)
        end)

      assert result == component
      assert calls == []
    end

    test "Ctrl+E, Cmd+E and Alt+E do nothing" do
      component = drawer()

      for mod <- [:ctrl_key, :meta_key, :alt_key] do
        {result, calls} =
          js_calls(fn ->
            GamePage.action(:shortcut_eraser, %{event: key("e", %{mod => true})}, component)
          end)

        assert result == component
        assert calls == []
      end
    end

    test "Ctrl+Z and Cmd+Z undo once, like the toolbar button" do
      component = drawer()

      for {via, mod} <- [ctrl: :ctrl_key, meta: :meta_key] do
        params = %{via: via, event: key("z", %{mod => true})}
        {result, calls} = js_calls(fn -> GamePage.action(:shortcut_undo, params, component) end)

        assert result == component
        assert calls == [{:undoStroke, []}]
      end

      {_result, calls} = js_calls(fn -> GamePage.action(:undo_drawing, %{}, component) end)
      assert calls == [{:undoStroke, []}]
    end

    test "Ctrl+Cmd+Z fires both bindings with one event, and undoes once" do
      component = drawer()
      event = key("z", %{ctrl_key: true, meta_key: true})

      {_result, calls} =
        js_calls(fn ->
          component
          |> then(&GamePage.action(:shortcut_undo, %{via: :ctrl, event: event}, &1))
          |> then(&GamePage.action(:shortcut_undo, %{via: :meta, event: event}, &1))
        end)

      assert calls == [{:undoStroke, []}]
    end

    test "Ctrl/Cmd+Shift+Z (redo) and a held Ctrl/Cmd+Z do nothing" do
      component = drawer()

      for {via, mod} <- [ctrl: :ctrl_key, meta: :meta_key],
          extra <- [%{shift_key: true}, %{repeat: true}] do
        event = key("z", Map.put(extra, mod, true))

        {result, calls} =
          js_calls(fn ->
            GamePage.action(:shortcut_undo, %{via: via, event: event}, component)
          end)

        assert result == component
        assert calls == [], "#{via} #{inspect(extra)} called #{inspect(calls)}"
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
  # renders its own forms and the layout's; no other page binds N.
  describe "typing guards" do
    for {module, path, guard} <- [
          {HomePage, "lib/scrawly_web/pages/home_page.ex",
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
