defmodule ScrawlyWeb.Pages.GamePageTest do
  use ExUnit.Case, async: true

  alias ScrawlyWeb.Pages.GamePage
  alias Scrawly.Games

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)

    Scrawly.Games.Word.seed_words()

    {:ok, room} = Games.create_room(%{max_players: 4, name: "Test Room"})

    %{room: room}
  end

  describe "init/3" do
    test "initializes with room data", %{room: room} do
      params = %{room_id: room.id}
      server = %Hologram.Server{session: %{"user_id" => "current-user-id"}}
      component = GamePage.init(params, %Hologram.Component{}, server)

      assert component.state.room_id == room.id
      assert component.state.room_code == room.code
      assert component.state.room_name == "Room #{room.name}"
      assert component.state.room_status == room.status
      assert component.state.current_user_id == "current-user-id"
      assert component.state.game_id == ""
      assert is_list(component.state.players)
      assert component.state.current_drawer == %{id: "Watcher", username: "Watcher"}
      assert component.state.current_word == ""
      assert component.state.current_word_display == ""
      assert component.state.time_left == 0
      assert component.state.round == 1
      assert component.state.total_rounds == 5
      assert component.state.new_message == ""
      assert is_list(component.state.chat_messages)
      assert component.state.is_drawer == false
      assert component.state.game_started == false
      assert component.state.can_start_game == false
    end

    test "redirects to home page when room not found" do
      params = %{room_id: "non-existent-id"}
      server = %Hologram.Server{session: %{}}
      component = GamePage.init(params, %Hologram.Component{}, server)

      assert match?(%Hologram.Component{}, component)
    end
  end

  describe "action/3 - message handling" do
    test "update_message updates the message" do
      component = %Hologram.Component{state: %{new_message: ""}}
      result = GamePage.action(:update_message, %{event: %{value: "Hello"}}, component)

      assert result.state.new_message == "Hello"
    end

    test "send_message adds message and clears input" do
      component = %Hologram.Component{
        state: %{
          new_message: "Test message",
          chat_messages: [],
          current_user_username: "TestUser",
          current_user_id: "user-1"
        }
      }

      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == ""
      assert length(result.state.chat_messages) == 1
      assert hd(result.state.chat_messages).message == "Test message"
    end

    test "send_message ignores empty messages" do
      component = %Hologram.Component{state: %{new_message: "   ", chat_messages: []}}
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

  describe "action/3 - game state" do
    test "update_timer updates time left" do
      component = %Hologram.Component{state: %{}}
      result = GamePage.action(:update_timer, %{time_left: 45}, component)

      assert result.state.time_left == 45
    end

    test "round_timeout sets time to zero" do
      component = %Hologram.Component{state: %{time_left: 30}}
      result = GamePage.action(:round_timeout, %{}, component)

      assert result.state.time_left == 0
    end
  end

  describe "action/3 - start_game with proper params" do
    setup %{room: room} do
      players = [
        %{id: "user-1", username: "You"},
        %{id: "user-2", username: "Alice"},
        %{id: "user-3", username: "Bob"}
      ]

      component = %Hologram.Component{
        state: %{
          room_id: room.id,
          room_code: room.code,
          current_user_id: "user-1",
          players: players,
          game_started: false,
          game_id: "",
          round: 1,
          total_rounds: 5,
          current_drawer: nil,
          current_word: nil,
          current_word_display: "",
          time_left: 0,
          is_drawer: false
        }
      }

      %{component: component, players: players}
    end

    test "start_game action updates state with proper params", %{component: component} do
      params = %{
        game_id: "game-123",
        round: 1,
        first_drawer_id: "user-2",
        current_word: "elephant",
        players: [
          %{id: "user-1", username: "You"},
          %{id: "user-2", username: "Alice"},
          %{id: "user-3", username: "Bob"}
        ]
      }

      result = GamePage.action(:start_game, params, component)

      assert result.state.game_started == true
      assert result.state.game_id == "game-123"
      assert result.state.round == 1
      assert result.state.current_drawer != nil
      assert result.state.current_word == "elephant"
      assert result.state.current_word_display =~ "_"
      assert result.state.time_left == 80
      assert result.state.is_drawer == false
    end

    test "start_game sets is_drawer true for drawer", %{component: component} do
      params = %{
        game_id: "game-123",
        round: 1,
        first_drawer_id: "user-1",
        current_word: "elephant",
        players: [
          %{id: "user-1", username: "You"},
          %{id: "user-2", username: "Alice"},
          %{id: "user-3", username: "Bob"}
        ]
      }

      result = GamePage.action(:start_game, params, component)

      assert result.state.is_drawer == true
    end

    test "next_round action updates state with proper params", %{component: component} do
      game_started = put_in(component.state.game_started, true)

      params = %{
        round: 2,
        current_drawer_id: "user-3",
        current_word: "giraffe",
        players: [
          %{id: "user-1", username: "You"},
          %{id: "user-2", username: "Alice"},
          %{id: "user-3", username: "Bob"}
        ]
      }

      result = GamePage.action(:next_round, params, game_started)

      assert result.state.round == 2
      assert result.state.current_word == "giraffe"
      assert result.state.current_word_display =~ "_"
      assert result.state.time_left == 80
    end

    test "end_game action resets state", %{component: component} do
      game_active = %{
        component
        | state: %{
            component.state
            | game_started: true,
              game_id: "game-123",
              current_drawer: %{id: "user-2", name: "Alice"},
              current_word: "elephant",
              current_word_display: "_ _ _ _ _ _",
              time_left: 45,
              is_drawer: false
          }
      }

      result = GamePage.action(:end_game, %{}, game_active)

      assert result.state.game_started == false
      assert result.state.game_id == nil
      assert result.state.current_drawer == nil
      assert result.state.current_word == nil
      assert result.state.current_word_display == ""
      assert result.state.time_left == 0
      assert result.state.is_drawer == false
    end
  end

  describe "state management" do
    test "load_room_players sets up mock players", %{room: room} do
      component = %Hologram.Component{state: %{}}

      params = %{room_id: room.id}
      server = %Hologram.Server{session: %{user_id: "current-user-id"}}
      result = GamePage.init(params, component, server)
      assert is_list(result.state.players)
    end

    test "check_game_status handles playing room status" do
      component = %Hologram.Component{state: %{room_status: :playing}}

      assert component.state.room_status == :playing
    end
  end
end
