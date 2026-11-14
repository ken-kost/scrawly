defmodule ScrawlyWeb.Pages.GamePageTest do
  # Shared sandbox: init/3 starts a RoomServer process that reads the DB.
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  setup do
    creator = create_user()
    room = start_room(creator)

    %{room: room, creator: creator}
  end

  describe "init/3" do
    test "initializes with room data for the creator", %{room: room, creator: creator} do
      assert {component, server} =
               GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(creator))

      assert %Hologram.Component{state: state} = component
      assert %Hologram.Server{} = server
      assert state.room_id == room.id
      assert state.room_code == room.code
      assert state.room_name == "Room #{room.name}"
      assert state.room_status == :lobby
      assert state.game_id == ""
      assert state.game_started == false
      assert [%{id: creator_id}] = state.players
      assert creator_id == creator.id
      assert state.is_creator == true
      assert state.current_user_id == creator.id
      assert state.time_left == 0
      assert state.is_drawer == false
      assert state.current_word == nil
      assert state.current_word_display == ""
      assert state.word_length == 0
      assert state.revealed_word == nil
      assert state.word_choices == []
      assert state.watching? == false
      assert component.next_action.name == :poll_room
    end

    test "a visitor without an account watches and is never the drawer", %{room: room} do
      assert {component, _server} =
               GamePage.init(%{room_id: room.id}, %Hologram.Component{}, anon_server())

      assert component.state.current_user_id == nil
      assert component.state.is_creator == false
      assert component.state.is_drawer == false
      assert component.state.watching? == true
      assert component.next_action.name == :do_join_as_watcher
    end

    test "redirects to home page when room not found" do
      params = %{room_id: Ecto.UUID.generate()}
      server = %Hologram.Server{session: %{}}
      component = GamePage.init(params, %Hologram.Component{}, server)

      assert match?(%Hologram.Component{}, component)
    end
  end

  describe "action/3" do
    test "update_message updates the message" do
      component = %Hologram.Component{state: %{new_message: ""}}
      result = GamePage.action(:update_message, %{event: %{value: "Hello"}}, component)

      assert result.state.new_message == "Hello"
    end

    test "send_message clears input and sends via command" do
      component = %Hologram.Component{
        state: %{
          new_message: "Test message",
          chat_messages: [],
          current_user_id: "user-1",
          current_user_username: "Alice",
          is_drawer: false,
          correct_guessers: [],
          current_word: nil,
          rate_limited: false,
          message_timestamps: [],
          room_id: "test-room",
          drawing_path: "",
          drawing?: false,
          drawing_sent_length: 0
        }
      }

      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == ""
      # Messages go to the server via :submit_guess, not added locally
      assert result.state.chat_messages == []
      assert result.next_command.name == :submit_guess
      assert result.next_command.params == %{room_id: "test-room", text: "Test message"}
    end

    test "send_message ignores empty messages" do
      component = %Hologram.Component{
        state: %{
          new_message: "   ",
          chat_messages: [],
          current_user_id: "user-1",
          current_user_username: "Alice",
          is_drawer: false,
          correct_guessers: [],
          current_word: nil,
          rate_limited: false,
          message_timestamps: [],
          room_id: "test-room",
          drawing_path: "",
          drawing?: false,
          drawing_sent_length: 0
        }
      }

      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == "   "
      assert length(result.state.chat_messages) == 0
    end

    test "go_home navigates to home page" do
      component = %Hologram.Component{state: %{}}
      result = GamePage.action(:go_home, %{}, component)

      assert match?(%Hologram.Component{}, result)
    end
  end

  # A :room_refreshed payload as RoomServer.View.for_viewer/2 builds it for
  # user-1, a guesser: no word, no choices.
  defp view_params(component, overrides) do
    Map.merge(
      %{
        room_id: component.state.room_id,
        status: :playing,
        players: component.state.players,
        version: 1,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        time_left: 80,
        round_active: true,
        correct_guessers: [],
        chat_messages: [],
        drawing_strokes: [],
        name: "Test Room",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        past_games: [],
        last_game_id: nil,
        phase: :drawing,
        choice_time_left: 0,
        word_display: "_ _ _ _ _ _ _ _ _",
        word_length: 9,
        revealed_word: nil,
        is_drawer: false,
        drawer_name: "Alice",
        current_word: nil,
        word_choices: []
      },
      overrides
    )
  end

  defp started(component, overrides) do
    state =
      Map.merge(
        component.state,
        %{
          game_started: true,
          game_id: "g1",
          round: 1,
          phase: :drawing,
          room_status: :playing,
          current_drawer: %{id: "user-2", username: "Alice"},
          current_word_display: "_ _ _ _ _ _ _ _ _",
          word_length: 9,
          time_left: 60,
          version: 4
        }
      )

    %{component | state: Map.merge(state, overrides)}
  end

  describe "room_refreshed game transitions" do
    setup %{room: room} do
      players = [
        %{id: "user-1", username: "You", score: 0},
        %{id: "user-2", username: "Alice", score: 0},
        %{id: "user-3", username: "Bob", score: 0}
      ]

      component = %Hologram.Component{
        state: %{
          room_id: room.id,
          room_code: room.code,
          current_user_id: "user-1",
          players: players,
          game_id: nil,
          game_started: false,
          can_start_game: true,
          round: 0,
          total_rounds: 5,
          current_drawer: nil,
          current_word: nil,
          current_word_display: "",
          word_length: 0,
          revealed_word: nil,
          time_left: 0,
          is_drawer: false,
          is_creator: true,
          chat_messages: [],
          new_message: "",
          correct_guessers: [],
          used_words: [],
          rate_limited: false,
          message_timestamps: [],
          watching?: false,
          leaving?: false,
          room_status: :lobby,
          room_name: "Room ABCD",
          current_user_username: "You",
          version: 0,
          phase: :idle,
          word_choices: [],
          choice_time_left: 0,
          past_games: [],
          drawing_strokes: [],
          drawing_path: "",
          drawing?: false,
          drawing_sent_length: 0
        }
      }

      %{component: component, players: players}
    end

    test "room_refreshed detects game start", %{component: component} do
      result = GamePage.action(:room_refreshed, view_params(component, %{}), component)

      assert result.state.game_started == true
      assert result.state.game_id == "g1"
      assert result.state.round == 1
      assert result.state.current_drawer.id == "user-2"
      assert result.state.current_word_display == "_ _ _ _ _ _ _ _ _"
      assert result.state.word_length == 9
      assert result.state.current_word == nil
      assert result.state.time_left == 80
      assert result.state.is_drawer == false
    end

    test "room_refreshed redirects to score page on game end", %{component: component} do
      started = started(component, %{round: 3, time_left: 20})

      params =
        view_params(component, %{
          status: :lobby,
          version: 10,
          game_id: nil,
          current_round: 0,
          current_drawer_id: nil,
          time_left: 0,
          round_active: false,
          phase: :idle,
          word_display: "",
          word_length: 0,
          drawer_name: "Unknown",
          last_game_id: "g1"
        })

      result = GamePage.action(:room_refreshed, params, started)

      assert result.next_page == {ScrawlyWeb.Pages.GameScorePage, [game_id: "g1"]}
    end

    test "room_refreshed detects timer tick", %{component: component} do
      started = started(component, %{})

      params =
        view_params(component, %{version: 5, time_left: 55, word_display: "b _ _ _ _ _ _ _ _"})

      result = GamePage.action(:room_refreshed, params, started)

      assert result.state.time_left == 55
      assert result.state.current_word_display == "b _ _ _ _ _ _ _ _"
    end

    test "room_refreshed keeps local strokes: replies carry none", %{component: component} do
      stroke = %{path: "M0 0 L1 1", color: "#000000", width: 2}
      started = started(component, %{drawing_strokes: [stroke]})

      result = GamePage.action(:room_refreshed, view_params(component, %{version: 5}), started)

      assert result.state.drawing_strokes == [stroke]
    end

    test "room_refreshed stores the revealed word at :round_end", %{component: component} do
      params =
        view_params(component, %{
          version: 5,
          phase: :round_end,
          time_left: 0,
          round_active: false,
          word_display: "b _ _ _ e _ _ _ y",
          revealed_word: "butterfly"
        })

      result = GamePage.action(:room_refreshed, params, started(component, %{}))

      assert result.state.revealed_word == "butterfly"
      assert result.state.phase == :round_end
      assert result.state.current_word == nil
    end
  end

  describe "room_delta word fields" do
    setup %{room: room} do
      component = %Hologram.Component{
        state: %{
          room_id: room.id,
          is_creator: false,
          players: [],
          watchers: [],
          past_games: [],
          correct_guessers: [],
          leaving?: false,
          game_started: true,
          round: 1,
          phase: :drawing,
          version: 4,
          time_left: 60,
          choice_time_left: 0,
          current_word: nil,
          current_word_display: "_ _ _ _ _ _ _ _ _",
          word_length: 9,
          revealed_word: nil
        }
      }

      delta = %{
        room_id: room.id,
        status: :playing,
        players: [],
        watchers: [],
        version: 5,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        time_left: 30,
        round_active: true,
        correct_guessers: [],
        phase: :drawing,
        choice_time_left: 0,
        last_game_id: nil,
        max_players: 4,
        past_games: [],
        word_display: "b _ _ _ _ _ _ _ y",
        word_length: 9,
        revealed_word: nil
      }

      %{component: component, delta: delta}
    end

    test "a tick updates the hint without a poll", %{component: component, delta: delta} do
      result = GamePage.action(:room_delta, delta, component)

      assert result.state.current_word_display == "b _ _ _ _ _ _ _ y"
      assert result.state.time_left == 30
      assert result.next_command == nil
    end

    test "never touches the drawer's word", %{component: component, delta: delta} do
      drawer = %{component | state: %{component.state | current_word: "butterfly"}}

      result = GamePage.action(:room_delta, delta, drawer)

      assert result.state.current_word == "butterfly"
    end

    test ":round_end stores the revealed word and polls", %{component: component, delta: delta} do
      ended = %{delta | phase: :round_end, time_left: 0, revealed_word: "butterfly"}

      result = GamePage.action(:room_delta, ended, component)

      assert result.state.revealed_word == "butterfly"
      assert result.next_command.name == :poll_room_state
    end

    test "a stale version is ignored", %{component: component, delta: delta} do
      result = GamePage.action(:room_delta, %{delta | version: 4}, component)

      assert result.state == component.state
    end
  end

  describe ":choose_word" do
    test "sends only the room and the word" do
      component = %Hologram.Component{
        state: %{room_id: "r1", is_drawer: true, phase: :choosing, current_user_id: "user-1"}
      }

      result = GamePage.action(:choose_word, %{word: "apple"}, component)

      assert result.next_command.name == :choose_word
      assert result.next_command.params == %{room_id: "r1", word: "apple"}
    end
  end
end
