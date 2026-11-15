defmodule ScrawlyWeb.Pages.GamePageRobustnessTest do
  @moduledoc """
  Page side of the QA "game/realtime" fixes: the private hint for a chat line
  that contained the word (G5) and the reason shown for a refused join (G10).
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Template.Renderer
  alias ScrawlyWeb.Components.ChatBox
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  defp component(state) do
    %Hologram.Component{
      props: %{room_id: "r1"},
      state: Map.merge(%{chat_notice: nil, chat_notice_gen: 0, join_notice: nil}, state)
    }
  end

  describe "G5: a chat line that contained the word" do
    setup do
      creator = create_user()
      guesser = create_user()
      room = start_room(creator)

      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(guesser)).next_action.name ==
               :room_resynced

      start_drawing!(room, creator)
      %{room: room, guesser: guesser}
    end

    test "is answered privately and never reaches the room", %{room: room, guesser: guesser} do
      before = room_state!(room.id)

      result =
        GamePage.command(
          :submit_guess,
          %{room_id: room.id, text: "lol it is ZZYZX!"},
          server_for(guesser)
        )

      assert result.next_action.name == :guess_result
      assert result.next_action.params.outcome == :suppressed
      assert result.broadcasts == []

      after_state = room_state!(room.id)
      assert after_state.chat_messages == before.chat_messages
      assert after_state.correct_guessers == []
      assert after_state.seq == before.seq
    end

    test "the page shows only the sender a hint, cleared after 4 s" do
      result = GamePage.action(:guess_result, %{outcome: :suppressed}, component(%{}))

      assert result.state.chat_notice =~ "contains the word"
      assert result.state.chat_notice_gen == 1
      assert result.next_action.name == :clear_chat_notice
      assert result.next_action.params == %{gen: 1}
      assert result.next_action.delay == 4_000

      cleared = GamePage.action(:clear_chat_notice, %{gen: 1}, result)
      assert cleared.state.chat_notice == nil

      # A newer hint is not cleared by an older timer.
      newer = GamePage.action(:guess_result, %{outcome: :suppressed}, result)
      assert GamePage.action(:clear_chat_notice, %{gen: 1}, newer).state.chat_notice != nil
    end

    test "the chat box renders the hint" do
      {html, _registry, _server} =
        ChatBox.template().(%{
          messages: [],
          current_message: "",
          current_user_id: "u1",
          disabled: false,
          is_drawer: false,
          rate_limited: false,
          notice: "not sent: your message contains the word",
          got_it: nil
        })
        |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

      assert html =~ "not sent: your message contains the word"
    end
  end

  describe "G10: a refused join" do
    test "shows why in the lobby" do
      for {reason, text} <- [
            creator_not_present: "host",
            not_in_lobby: "game is in progress",
            something_else: "can't join"
          ] do
        result =
          GamePage.action(
            :command_denied,
            %{command: :join_room, reason: reason},
            component(%{leaving?: false, resync_requested_at: nil, last_seq: 0})
          )

        assert result.state.join_notice =~ text
      end
    end

    test "other denials leave the join notice alone" do
      result =
        GamePage.action(
          :command_denied,
          %{command: :start_game, reason: :not_creator},
          component(%{leaving?: false, resync_requested_at: nil, last_seq: 0})
        )

      assert result.state.join_notice == nil
    end
  end
end
