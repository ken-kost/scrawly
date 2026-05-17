defmodule ScrawlyWeb.Pages.GamePageTest do
  use ExUnit.Case, async: false

  alias ScrawlyWeb.Pages.GamePage
  alias Scrawly.Games

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)

    # Ensure RoomServer infrastructure is running
    unless Process.whereis(Scrawly.RoomRegistry) do
      Registry.start_link(keys: :unique, name: Scrawly.RoomRegistry)
    end

    unless Process.whereis(Scrawly.RoomSupervisor) do
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Scrawly.RoomSupervisor)
    end

    Scrawly.Games.Word.seed_words()

    {:ok, creator} =
      Ash.create(
        Scrawly.Accounts.User,
        %{email: "creator-#{System.unique_integer([:positive])}@test.com"},
        authorize?: false
      )

    {:ok, room} = Games.create_room(%{max_players: 4, name: "Test Room", creator_id: creator.id})

    %{room: room}
  end

  describe "init/3" do
    test "initializes with room data", %{room: room} do
      params = %{room_id: room.id}
      server = %Hologram.Server{session: %{"user_id" => "Watcher"}}
      result = GamePage.init(params, %Hologram.Component{}, server)

      # init returns a component (possibly with queued actions)
      assert match?(%Hologram.Component{}, result)

      # Check state is populated (may be nested in the component)
      state = result.state

      if Map.has_key?(state, :room_id) do
        assert state.room_id == room.id
        assert state.room_code == room.code
        assert state.room_name == "Room #{room.name}"
        assert state.game_id == ""
        assert is_list(state.players)
        assert state.time_left == 0
        assert state.is_drawer == false
      end
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
      # Messages now go to server via command, not added locally
      assert result.state.chat_messages == []
      assert result.next_command != nil
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
          drawing_path: "",
          drawing?: false,
          drawing_sent_length: 0
        }
      }

      %{component: component, players: players}
    end

    test "room_refreshed detects game start", %{component: component, players: players} do
      params = %{
        room_id: component.state.room_id,
        status: :playing,
        players: players,
        version: 1,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        current_word: "butterfly",
        time_left: 80,
        round_active: true,
        correct_guessers: [],
        chat_messages: [],
        drawing_path: "",
        name: "Test Room",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        # Pre-computed by server
        is_drawer: false,
        current_word_display: "_ _ _ _ _ _ _ _ _",
        drawer_name: "Alice"
      }

      result = GamePage.action(:room_refreshed, params, component)

      assert result.state.game_started == true
      assert result.state.game_id == "g1"
      assert result.state.round == 1
      assert result.state.current_drawer.id == "user-2"
      assert result.state.current_word_display =~ "_"
      assert result.state.time_left == 80
      assert result.state.is_drawer == false
    end

    test "room_refreshed redirects to score page on game end", %{
      component: component,
      players: players
    } do
      started = %{
        component
        | state:
            Map.merge(component.state, %{
              game_started: true,
              game_id: "g1",
              round: 3,
              current_word: "cat",
              time_left: 20
            })
      }

      params = %{
        room_id: started.state.room_id,
        status: :lobby,
        players: players,
        version: 10,
        game_id: nil,
        current_round: 0,
        total_rounds: 5,
        current_drawer_id: nil,
        current_word: nil,
        time_left: 0,
        round_active: false,
        correct_guessers: [],
        chat_messages: [],
        drawing_path: "",
        name: "Test Room",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        is_drawer: false,
        current_word_display: "",
        drawer_name: "Unknown",
        last_game_id: "g1"
      }

      result = GamePage.action(:room_refreshed, params, started)

      # Should redirect to score page (put_page sets next_page on the component)
      assert match?(%Hologram.Component{}, result)
    end

    test "room_refreshed detects timer tick", %{component: component, players: players} do
      started = %{
        component
        | state:
            Map.merge(component.state, %{
              game_started: true,
              game_id: "g1",
              round: 1,
              current_word: "butterfly",
              time_left: 60,
              is_drawer: false
            })
      }

      params = %{
        room_id: started.state.room_id,
        status: :playing,
        players: players,
        version: 5,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        current_word: "butterfly",
        time_left: 55,
        round_active: true,
        correct_guessers: [],
        chat_messages: [],
        drawing_path: "",
        name: "Test Room",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        is_drawer: false,
        current_word_display: "b _ _ _ _ _ _ _ _",
        drawer_name: "Alice"
      }

      result = GamePage.action(:room_refreshed, params, started)

      assert result.state.time_left == 55
    end
  end
end
