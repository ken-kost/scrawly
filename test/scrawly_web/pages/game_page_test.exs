defmodule ScrawlyWeb.Pages.GamePageTest do
  # Shared sandbox: init/3 starts a RoomServer process that reads the DB.
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Template.Renderer
  alias Scrawly.Games
  alias Scrawly.Games.RoomServer
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
      assert state.room_missing? == false
      # The page param stays a prop (component.props.room_id), never state.
      refute Map.has_key?(state, :room_id)
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
      assert component.next_action.name == :mounted
      assert component.next_action.params == %{next: :poll_room, delay: 500}
      assert component.next_page == nil

      html = render_template(state, %{room_id: room.id})
      assert html =~ "game-page-marker"
      assert html =~ "Room #{room.name}"
      refute html =~ "room not found"
    end

    test "a visitor without an account watches and is never the drawer", %{room: room} do
      assert {component, _server} =
               GamePage.init(%{room_id: room.id}, %Hologram.Component{}, anon_server())

      assert component.state.current_user_id == nil
      assert component.state.is_creator == false
      assert component.state.is_drawer == false
      assert component.state.watching? == true
      assert component.next_action.name == :mounted
      assert component.next_action.params == %{next: :do_join_as_watcher, delay: 0}
    end
  end

  # put_page/3 does nothing from init, so these branches must render on their
  # own and leave through the action queued for the mount.
  describe "init/3 for a room that can't be shown" do
    test "an unknown room renders the placeholder and goes home", %{creator: creator} do
      for room_id <- [Ecto.UUID.generate(), "not-a-room-id"],
          server <- [server_for(creator), anon_server()] do
        component = GamePage.init(%{room_id: room_id}, %Hologram.Component{}, server)

        assert %Hologram.Component{state: state} = component
        assert state == %{room_missing?: true}
        assert component.next_action.name == :go_home
        assert component.next_page == nil
        refute RoomServer.room_exists?(room_id)

        html = render_template(state)
        assert html =~ "room not found"
        refute html =~ "game-page-marker"
      end
    end

    test "a dissolved room is not started again", %{room: room, creator: creator} do
      kill_room!(room)
      {:ok, %{status: :ended}} = Games.dissolve_room(room.id)

      component = GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(creator))

      assert component.state == %{room_missing?: true}
      assert component.next_action.name == :go_home
      assert component.next_page == nil
      assert render_template(component.state) =~ "room not found"
      # gen_server unregisters the name before start_child returns the error.
      refute RoomServer.room_exists?(room.id)

      assert RoomServer.ensure_started(room.id) == {:error, :room_ended}
      refute RoomServer.room_exists?(room.id)
    end

    test "a room in its post-game window goes to the score page", ctx do
      %{room: room, creator: creator} = ctx
      {:ok, game} = Games.create_game(room.id, 1)
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
      :sys.replace_state(pid, &%{&1 | status: :post_game, last_game_id: game.id})

      {component, _server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(creator))

      assert component.state.room_missing? == false
      assert component.next_page == nil
      assert component.next_action.name == :go_score
      assert component.next_action.params == %{game_id: game.id}

      result = GamePage.action(:go_score, component.next_action.params, component)

      assert result.next_page == {ScrawlyWeb.Pages.GameScorePage, [game_id: game.id]}
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
        props: %{room_id: "test-room"},
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
        props: %{room_id: "test-room"},
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
          drawing_path: "",
          drawing?: false,
          drawing_sent_length: 0
        }
      }

      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == "   "
      assert length(result.state.chat_messages) == 0
    end

    test "go_home navigates to home page, whatever the state" do
      component = %Hologram.Component{state: %{room_missing?: true}}
      result = GamePage.action(:go_home, %{}, component)

      assert result.next_page == ScrawlyWeb.Pages.HomePage
    end
  end

  # The page template alone (no layout), rendered as the server does on load:
  # its vars are the page params (props) merged with the state.
  defp render_template(state, params \\ %{}) do
    {html, _registry, _server} =
      GamePage.template().(Map.merge(params, state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  # A :room_refreshed payload as RoomServer.View.for_viewer/2 builds it for
  # user-1, a guesser: no word, no choices.
  defp view_params(component, overrides) do
    Map.merge(
      %{
        room_id: component.props.room_id,
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
        props: %{room_id: room.id},
        state: %{
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
      stroke = %{id: "s-1", path: "M0 0 L1 1", color: "#000000", width: 2}
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
        props: %{room_id: room.id},
        state: %{
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
        props: %{room_id: "r1"},
        state: %{is_drawer: true, phase: :choosing, current_user_id: "user-1"}
      }

      result = GamePage.action(:choose_word, %{word: "apple"}, component)

      assert result.next_command.name == :choose_word
      assert result.next_command.params == %{room_id: "r1", word: "apple"}
    end
  end
end
