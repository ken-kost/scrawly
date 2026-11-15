defmodule ScrawlyWeb.Pages.GamePageStartTest do
  @moduledoc """
  Starting a game from the lobby (create-room-form): the start button reads
  "preparing words…" while the start command runs (it makes the AI call for
  a themed room) and comes back when the start is refused or never answered;
  the one chat line about a themed room's words is in plain words.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Component
  alias Hologram.Component.Action
  alias Hologram.Template.Renderer
  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.GamePage
  alias ScrawlyWeb.Pages.GamePage.Commands

  @moduletag :capture_log

  defp join!(room, user) do
    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
             :room_resynced
  end

  defp lobby(attrs \\ %{}) do
    creator = create_user()
    room = start_room(creator, Map.merge(%{max_players: 4}, attrs))
    join!(room, create_user())

    {component, _server} =
      GamePage.init(%{room_id: room.id}, %Component{}, server_for(creator))

    %{room: room, creator: creator, page: component}
  end

  defp render(component) do
    {html, _registry, _server} =
      GamePage.template().(Map.merge(component.props, component.state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  defp start_button(html) do
    [button] =
      Regex.run(~r/<button class="app-btn app-btn-primary app-btn-lg"[^>]*>.*?<\/button>/s, html)

    button
  end

  describe "the start button" do
    test "reads preparing words… and is off while the start command runs" do
      %{room: room, page: page} = lobby()
      page = %{page | props: %{room_id: room.id}}

      assert page.state.starting_game? == false
      assert start_button(render(page)) =~ ~r/>\s*start game\s*</

      pressed = GamePage.action(:request_start_game, %{}, page)

      assert pressed.state.starting_game? == true
      assert pressed.next_command.name == :start_game
      assert pressed.next_command.params == %{room_id: room.id}

      assert pressed.next_action == %Action{
               name: :start_game_timed_out,
               params: %{attempt: 1},
               delay: 90_000
             }

      button = start_button(render(pressed))
      assert button =~ "disabled"
      assert button =~ ~r/>\s*preparing words…\s*</

      # A second press sends nothing.
      again = GamePage.action(:request_start_game, %{}, %{pressed | next_command: nil})
      assert again.next_command == nil
    end

    test "the started game's snapshot ends it" do
      %{room: room, creator: creator, page: page} = lobby()
      pressed = GamePage.action(:request_start_game, %{}, %{page | props: %{room_id: room.id}})

      server = GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))
      assert server.next_action == nil

      {:ok, view} = RoomServer.get_view(room.id, creator.id)
      started = GamePage.action(:room_resynced, Map.put(view, :socket_token, "t"), pressed)

      assert started.state.game_started == true
      assert started.state.starting_game? == false
    end

    test "a refused start gives the button back" do
      %{room: room, page: page} = lobby()
      pressed = GamePage.action(:request_start_game, %{}, %{page | props: %{room_id: room.id}})

      denied =
        GamePage.action(
          :command_denied,
          %{command: :start_game, reason: :not_enough_players},
          pressed
        )

      assert denied.state.starting_game? == false

      other = GamePage.action(:command_denied, %{command: :submit_guess, reason: :x}, pressed)
      assert other.state.starting_game? == true
    end

    test "no answer in time gives the button back; an older timeout does nothing" do
      %{room: room, page: page} = lobby()
      pressed = GamePage.action(:request_start_game, %{}, %{page | props: %{room_id: room.id}})

      timed_out = GamePage.action(:start_game_timed_out, %{attempt: 1}, pressed)
      assert timed_out.state.starting_game? == false

      pressed_again = GamePage.action(:request_start_game, %{}, timed_out)
      assert pressed_again.state.start_game_attempt == 2
      assert GamePage.action(:start_game_timed_out, %{attempt: 1}, pressed_again) == pressed_again
    end

    test "can't be pressed without two players" do
      creator = create_user()
      room = start_room(creator)

      {page, _server} = GamePage.init(%{room_id: room.id}, %Component{}, server_for(creator))
      page = %{page | props: %{room_id: room.id}}

      assert GamePage.action(:request_start_game, %{}, page) == page
    end
  end

  describe "the AI status line" do
    test "plain words, by answer kind" do
      assert Commands.ai_status(:mixed, 18) == "words ready: 18 from your theme"
      assert Commands.ai_status(:words, 9) == "words ready: 9 from your theme"
      assert Commands.ai_status(:phrases, 14) == "phrases ready: 14 from your theme"

      assert Commands.ai_status(:mixed, 0) ==
               "couldn't get themed words, using the built-in list"

      assert Commands.ai_status(:phrases, 0) ==
               "couldn't get themed phrases, using the built-in list"
    end

    test "a themed room's start posts it; a failure posts no error text" do
      Scrawly.Games.sync_words()

      for {prompt, expected} <- [
            {"TEST ocean", ~r/\Awords ready: \d+ from your theme\z/},
            {"TEST fail", ~r/\Acouldn't get themed words, using the built-in list\z/},
            {"TEST raise", ~r/\Acouldn't get themed words, using the built-in list\z/}
          ] do
        %{room: room, creator: creator} = lobby(%{word_source: :ai, prompt: prompt})
        GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

        {:ok, state} = RoomServer.get_state(room.id)
        assert state.status == :playing
        lines = Enum.map(state.chat_messages, & &1.message)

        assert Enum.any?(lines, &(&1 =~ expected)), "#{prompt}: #{inspect(lines)}"

        for raw <- ["AI failed", "fake_model", "error", "inspect", "%{", "{:"] do
          refute Enum.any?(lines, &String.contains?(&1, raw)), "#{prompt}: #{inspect(lines)}"
        end
      end
    end

    test "a room on the built-in list posts none" do
      %{room: room, creator: creator} = lobby()
      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      {:ok, state} = RoomServer.get_state(room.id)
      refute Enum.any?(state.chat_messages, &(&1.message =~ "from your theme"))
      refute Enum.any?(state.chat_messages, &(&1.message =~ "built-in list"))
    end
  end
end
