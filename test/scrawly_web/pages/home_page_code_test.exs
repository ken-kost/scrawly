defmodule ScrawlyWeb.Pages.HomePageCodeTest do
  @moduledoc """
  Home's "have a code?" field (invites). The page checks the input first
  (empty, length, alphabet) and shows the problem under the field; a
  well-formed code goes to the server (`:join_by_code`), uppercased, which
  answers with the room (straight in, or through `/guest` for a signed-out
  visitor) or the line to show ("no room with that code", "too many tries,
  wait a minute").
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers

  alias Hologram.Component
  alias Hologram.Component.Action
  alias Hologram.Server
  alias Scrawly.Accounts.Throttle
  alias Scrawly.JsCallTrace
  alias ScrawlyWeb.Pages.HomePage

  @moduletag :capture_log

  defp home(overrides \\ %{}) do
    {component, _server} =
      HomePage.init(%{}, %Component{}, run_page_middleware(HomePage, %Server{session: %{}}))

    %{component | state: Map.merge(component.state, Map.new(overrides)), next_action: nil}
  end

  # Typing (the input's $change), then the form's $submit.
  defp submit(component, input) do
    component = HomePage.action(:update_room_code, %{event: %{value: input}}, component)
    HomePage.action(:join_by_code, %{event: %{"room_code" => input}}, component)
  end

  defp anon do
    run_page_middleware(HomePage, %Server{
      session: %{},
      session_id: "anon-home-code-#{System.unique_integer([:positive])}"
    })
  end

  defp render(state) do
    {html, _registry, _server} =
      HomePage.template().(state)
      |> Hologram.Template.Renderer.render_dom(
        %Hologram.Template.Renderer.Env{},
        %Hologram.Server{}
      )

    html
  end

  describe "the page" do
    test "starts empty, with no error" do
      state = home().state
      assert state.room_code_input == ""
      assert state.room_code_error == nil
      assert state.joining_by_code? == false
    end

    test "empty, short, long or wrong-character input is answered under the field" do
      for {input, message} <- [
            {"", "type a room code"},
            {"   ", "type a room code"},
            {"ab2", "room codes have 6 characters"},
            {"ab2cd7x", "room codes have 6 characters"},
            {"ab0cd7", "room codes use letters and the digits 2-7"}
          ] do
        result = submit(home(), input)

        assert result.state.room_code_error == message, inspect(input)
        assert result.next_command == nil
        assert result.state.joining_by_code? == false
      end
    end

    test "a well-formed code goes to the server uppercased, and the button waits" do
      result = submit(home(), " 45cv x7 ")

      assert result.next_command.name == :join_by_code
      assert result.next_command.params == %{code: "45CVX7"}
      assert result.state.joining_by_code? == true
      assert result.state.room_code_error == nil

      assert %Action{name: :join_by_code_timed_out, delay: 10_000, params: %{attempt: 1}} =
               result.next_action

      # A second submit while waiting sends nothing.
      again = HomePage.action(:join_by_code, %{}, %{result | next_command: nil})
      assert again.next_command == nil
    end

    test "typing clears the error" do
      component = submit(home(), "")
      assert component.state.room_code_error

      typed = HomePage.action(:update_room_code, %{event: %{value: "a"}}, component)
      assert typed.state.room_code_error == nil
      assert typed.state.room_code_input == "a"
    end

    test "a failure from the server is shown and the button comes back" do
      waiting = submit(home(), "zzzz22")

      failed =
        HomePage.action(:room_code_failed, %{message: "no room with that code"}, waiting)

      assert failed.state.room_code_error == "no room with that code"
      assert failed.state.joining_by_code? == false
      assert failed.state.room_code_input == "zzzz22"
    end

    test "no answer: only the latest lookup times out" do
      waiting = submit(home(), "zzzz22")

      timed_out = HomePage.action(:join_by_code_timed_out, %{attempt: 1}, waiting)
      assert timed_out.state.joining_by_code? == false
      assert timed_out.state.room_code_error == "no answer from the server, try again"

      stale = HomePage.action(:join_by_code_timed_out, %{attempt: 0}, waiting)
      assert stale.state.joining_by_code? == true
    end

    test "found: a signed-in visitor goes to the game page and the field resets" do
      waiting = submit(home(), "45cvx7")
      result = HomePage.action(:join_room_with_user, %{room_id: "r-1"}, waiting)

      assert result.next_page == {ScrawlyWeb.Pages.GamePage, [room_id: "r-1"]}
      assert result.state.joining_by_code? == false
      assert result.state.room_code_input == ""
    end

    test "found, signed out: a full page load of the guest path" do
      waiting = submit(home(), "45cvx7")
      path = "/guest?return_to=%2Fgame%2Fr-1"

      {result, calls} =
        JsCallTrace.js_calls(fn ->
          HomePage.action(:open_room_as_guest, %{path: path}, waiting)
        end)

      assert {:openPath, [^path]} = List.last(calls)
      assert result.state.joining_by_code? == false
    end

    test "the field, its button and its error render" do
      html = render(home().state)
      assert html =~ ~s(placeholder="have a code?")
      assert html =~ ~s(aria-label="room code")
      assert html =~ ~r{<button type="submit" class="app-btn app-btn-sm">\s*join\s*</button>}
      refute html =~ "code-join-error"

      html =
        render(home(room_code_input: "ZZZZ22", room_code_error: "no room with that code").state)

      assert html =~ ~s(value="ZZZZ22")
      assert html =~ "no room with that code"

      assert render(home(joining_by_code?: true).state) =~ "joining…"
    end
  end

  describe "command :join_by_code" do
    setup do
      creator = create_user()
      %{room: start_room(creator)}
    end

    test "a signed-in visitor joins the room, typed in either case", %{room: room} do
      for code <- [room.code, String.downcase(room.code)] do
        result = HomePage.command(:join_by_code, %{code: code}, signed_in_server(create_user()))

        assert %Action{name: :join_room_with_user, params: %{room_id: room_id}} =
                 result.next_action

        assert room_id == room.id
      end
    end

    test "a signed-out visitor is sent through /guest to the room", %{room: room} do
      result = HomePage.command(:join_by_code, %{code: room.code}, anon())

      assert %Action{name: :open_room_as_guest, params: %{path: path}} = result.next_action
      assert path == "/guest?return_to=%2Fgame%2F" <> room.id
    end

    test "a wrong code says so" do
      result = HomePage.command(:join_by_code, %{code: "zzzz22"}, anon())

      assert %Action{name: :room_code_failed, params: %{message: "no room with that code"}} =
               result.next_action
    end

    test "malformed codes get the page's message; a missing one is denied" do
      result = HomePage.command(:join_by_code, %{code: "ab"}, anon())
      assert result.next_action.params.message == "room codes have 6 characters"

      for params <- [%{}, %{code: 123}, nil, "zzzz22"] do
        result = HomePage.command(:join_by_code, params, anon())
        assert result.next_action.name == :command_denied
        assert result.next_action.params.reason == :invalid_params
      end
    end

    test "past the lookup cap: too many tries", %{room: room} do
      server = anon()
      {max, _} = Throttle.limit(:room_code)
      for _ <- 1..max, do: HomePage.command(:join_by_code, %{code: "zzzz22"}, server)

      result = HomePage.command(:join_by_code, %{code: room.code}, server)

      assert %Action{name: :room_code_failed, params: %{message: "too many tries, wait a minute"}} =
               result.next_action
    end
  end
end
