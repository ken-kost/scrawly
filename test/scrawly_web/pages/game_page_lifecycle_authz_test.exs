defmodule ScrawlyWeb.Pages.GamePageLifecycleAuthzTest do
  @moduledoc """
  Room lifecycle commands on GamePage take identity from the session only
  (ScrawlyWeb.Auth), never from params.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.GamePage
  alias ScrawlyWeb.Pages.GamePage.Commands

  @moduletag :capture_log

  setup do
    creator = create_user()
    player = create_user()
    stranger = create_user()
    room = start_room(creator)
    %{creator: creator, player: player, stranger: stranger, room: room}
  end

  defp join!(room, user) do
    result = GamePage.command(:join_room, %{room_id: room.id}, server_for(user))
    assert result.next_action.name == :room_resynced
    result
  end

  defp assert_denied(result, reason) do
    assert result.next_action.name == :command_denied
    assert result.next_action.params.reason == reason
    assert result.broadcasts == []
  end

  defp player_ids(room), do: Enum.map(room_state!(room.id).players, & &1.id)

  describe "removed commands" do
    test ":end_game and :fetch_past_games no longer exist" do
      refute function_exported?(Commands, :end_game, 2)
      refute function_exported?(Commands, :fetch_past_games, 2)

      for name <- [:end_game, :fetch_past_games] do
        assert_raise FunctionClauseError, fn ->
          GamePage.command(name, %{room_id: "x", game_id: "y"}, %Hologram.Server{})
        end
      end
    end
  end

  describe ":start_game" do
    test "a non-creator is denied even with forged players", ctx do
      %{room: room, creator: creator, player: player} = ctx
      join!(room, player)
      track_ai_calls()

      params = %{room_id: room.id, players: [%{id: player.id}], user_id: creator.id}
      result = GamePage.command(:start_game, params, server_for(player))

      assert_denied(result, :not_creator)
      assert games_for_room(room) == []
      assert room_state!(room.id).status == :lobby
      assert reload_room!(room).status == :lobby
      refute_received {:ai_call, _}
    end

    test "an account-less visitor is denied", %{room: room, player: player} do
      join!(room, player)

      result = GamePage.command(:start_game, %{room_id: room.id}, anon_server("x"))

      assert_denied(result, :unauthenticated)
      assert games_for_room(room) == []
    end

    test "the creator is denied with fewer than 2 players, before any AI call", ctx do
      %{creator: creator} = ctx
      ai_room = start_room(creator, %{word_source: :ai, prompt: "TEST ocean animals"})
      track_ai_calls()

      result = GamePage.command(:start_game, %{room_id: ai_room.id}, server_for(creator))

      assert_denied(result, :not_enough_players)
      assert games_for_room(ai_room) == []
      refute_received {:ai_call, _}
    end

    test "a non-creator in an AI room makes no AI call", ctx do
      %{creator: creator, player: player} = ctx
      ai_room = start_room(creator, %{word_source: :ai, prompt: "TEST ocean animals"})
      join!(ai_room, player)
      track_ai_calls()

      result = GamePage.command(:start_game, %{room_id: ai_room.id}, server_for(player))

      assert_denied(result, :not_creator)
      refute_received {:ai_call, _}
    end

    test "the creator starts; drawer and players come from the room; a second start is denied",
         ctx do
      %{room: room, creator: creator, player: player} = ctx
      seed_test_words()
      join!(room, player)

      forged = %{room_id: room.id, players: [%{id: player.id}, %{id: "ghost"}]}
      result = GamePage.command(:start_game, forged, server_for(creator))

      # No reply: the creator's page gets the start as broadcasts.
      assert result.next_action == nil
      assert result.broadcasts == []
      assert {:ok, %{is_drawer: true}} = RoomServer.get_view(room.id, creator.id)
      state = room_state!(room.id)
      assert state.status == :playing
      assert state.current_drawer_id == creator.id
      assert Enum.sort(player_ids(room)) == Enum.sort([creator.id, player.id])
      assert state.total_rounds == 2
      assert [game] = games_for_room(room)
      assert state.game_id == game.id

      {:ok, _} = RoomServer.update_player_score(room.id, player.id, 7)
      track_ai_calls()

      again = GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      assert_denied(again, :wrong_state)
      assert [^game] = games_for_room(room)
      after_state = room_state!(room.id)
      assert after_state.game_id == game.id
      assert Enum.find(after_state.players, &(&1.id == player.id)).score == 7
      refute_received {:ai_call, _}
    end
  end

  describe ":resync_room" do
    test "a forged user_id doesn't yield the drawer's view", ctx do
      %{room: room, creator: creator, player: player} = ctx
      seed_test_words()
      join!(room, player)
      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      forged = %{room_id: room.id, user_id: creator.id}
      as_player = GamePage.command(:resync_room, forged, server_for(player))
      assert as_player.next_action.name == :room_resynced
      assert as_player.next_action.params.is_drawer == false
      assert as_player.next_action.params.word_choices == []

      as_anon = GamePage.command(:resync_room, forged, anon_server("x"))
      assert as_anon.next_action.params.is_drawer == false
      assert as_anon.next_action.params.word_choices == []

      as_creator = GamePage.command(:resync_room, %{room_id: room.id}, server_for(creator))
      assert as_creator.next_action.params.is_drawer == true
      assert as_creator.next_action.params.word_choices != []
    end

    test "resubscribes only when asked, to the session user's own channel", ctx do
      %{room: room, player: player} = ctx
      join!(room, player)

      plain = GamePage.command(:resync_room, %{room_id: room.id}, server_for(player))
      assert plain.subscriptions == []

      forged = %{room_id: room.id, resubscribe: true, user_id: "someone-else"}
      again = GamePage.command(:resync_room, forged, server_for(player))

      assert Enum.sort(Enum.map(again.subscriptions, &elem(&1, 0))) ==
               Enum.sort([{:room, room.id}, {:room_player, room.id, player.id}])

      anon = GamePage.command(:resync_room, %{room_id: room.id, resubscribe: true}, anon_server())
      assert Enum.map(anon.subscriptions, &elem(&1, 0)) == [{:room, room.id}]
    end

    test "a room that is gone replies :room_dissolved", ctx do
      stop_room(ctx.room.id)
      assert_room_stopped(ctx.room.id)

      result = GamePage.command(:resync_room, %{room_id: ctx.room.id}, server_for(ctx.player))
      assert result.next_action.name == :room_dissolved
    end
  end

  describe ":join_room" do
    test "adds the session user, not a forged one", ctx do
      %{room: room, player: player, stranger: stranger} = ctx

      params = %{room_id: room.id, user_id: stranger.id}
      GamePage.command(:join_room, params, server_for(player))

      assert player.id in player_ids(room)
      refute stranger.id in player_ids(room)
      assert reload_user!(player).current_room_id == room.id
      assert reload_user!(stranger).current_room_id == nil
    end

    test "an account-less visitor is denied", %{room: room} do
      before = room_state!(room.id)

      result = GamePage.command(:join_room, %{room_id: room.id}, anon_server("x"))

      assert_denied(result, :unauthenticated)
      assert room_state!(room.id).players == before.players
    end
  end

  describe ":join_as_watcher / :leave_watcher" do
    test "a user watches under their own id and name; forged ones never reach chat", ctx do
      %{room: room, player: player, stranger: stranger} = ctx

      params = %{room_id: room.id, user_id: stranger.id, username: "TEST Forged Name"}
      GamePage.command(:join_as_watcher, params, server_for(player))

      state = room_state!(room.id)
      assert [%{id: id, username: name}] = state.watchers
      assert id == player.id
      assert name == player.username
      refute Enum.any?(chat_texts(state), &(&1 =~ "TEST Forged Name"))
    end

    test "an account-less visitor watches under a hashed key as Guest", %{room: room} do
      GamePage.command(:join_as_watcher, %{room_id: room.id}, anon_server("raw-session-id"))

      assert [%{id: "anon:" <> hex, username: "Guest"}] = room_state!(room.id).watchers
      assert String.length(hex) == 16
      refute hex =~ "raw-session-id"
    end

    test "a visitor with neither account nor session is denied", %{room: room} do
      result = GamePage.command(:join_as_watcher, %{room_id: room.id}, %Hologram.Server{})

      assert_denied(result, :unauthenticated)
      assert room_state!(room.id).watchers == []
    end

    test "joining a full watcher list is denied", %{room: room} do
      for i <- 1..50, do: RoomServer.join_as_watcher(room.id, %{id: "w#{i}", username: "w"})

      result = GamePage.command(:join_as_watcher, %{room_id: room.id}, anon_server("late"))

      assert_denied(result, :room_full)
      assert length(room_state!(room.id).watchers) == 50
    end

    test "leave_watcher removes only the caller", %{room: room, player: player} do
      GamePage.command(:join_as_watcher, %{room_id: room.id}, server_for(player))
      GamePage.command(:join_as_watcher, %{room_id: room.id}, anon_server("other"))

      params = %{room_id: room.id, watcher_id: player.id}
      result = GamePage.command(:leave_watcher, params, anon_server("third"))
      assert result.next_action.name == :go_home
      assert length(room_state!(room.id).watchers) == 2

      GamePage.command(:leave_watcher, %{room_id: room.id}, server_for(player))
      assert [%{id: "anon:" <> _}] = room_state!(room.id).watchers
    end
  end

  describe ":leave_room" do
    test "a non-creator with forged identity removes only themself", ctx do
      %{room: room, creator: creator, player: player} = ctx
      join!(room, player)

      params = %{room_id: room.id, user_id: creator.id, is_creator: true}
      result = GamePage.command(:leave_room, params, server_for(player))

      assert result.next_action.name == :go_home
      assert RoomServer.room_exists?(room.id)
      assert player_ids(room) == [creator.id]
      assert reload_room!(room).status == :lobby
      assert reload_user!(player).current_room_id == nil
      assert reload_user!(creator).current_room_id == room.id
    end

    test "the creator leaving dissolves the room", ctx do
      %{room: room, creator: creator, player: player} = ctx
      join!(room, player)

      result = GamePage.command(:leave_room, %{room_id: room.id}, server_for(creator))

      assert result.next_action.name == :go_home
      assert_room_stopped(room.id)
      assert reload_room!(room).status == :ended
      assert reload_user!(player).current_room_id == nil
      assert reload_user!(creator).current_room_id == nil
    end

    test "a non-member leaving succeeds silently and changes nothing", ctx do
      %{room: room, player: player, stranger: stranger} = ctx
      join!(room, player)
      before = room_state!(room.id)

      result = GamePage.command(:leave_room, %{room_id: room.id}, server_for(stranger))

      assert result.next_action.name == :go_home
      after_state = room_state!(room.id)
      assert after_state.players == before.players
      assert after_state.chat_messages == before.chat_messages
    end

    test "leaving twice is idempotent", %{room: room, player: player} do
      join!(room, player)

      GamePage.command(:leave_room, %{room_id: room.id}, server_for(player))
      again = GamePage.command(:leave_room, %{room_id: room.id}, server_for(player))

      assert again.next_action.name == :go_home
      assert RoomServer.room_exists?(room.id)
    end

    test "an account-less visitor just navigates", %{room: room} do
      before = room_state!(room.id)

      result = GamePage.command(:leave_room, %{room_id: room.id}, anon_server("x"))

      assert result.next_action.name == :go_home
      assert room_state!(room.id) == before
    end

    test "without a RoomServer, only the creator dissolves the DB room", ctx do
      %{room: room, creator: creator, player: player} = ctx
      join!(room, player)
      stop_room(room.id)

      GamePage.command(:leave_room, %{room_id: room.id}, server_for(player))
      assert reload_room!(room).status == :lobby
      assert reload_user!(player).current_room_id == nil
      assert reload_user!(creator).current_room_id == room.id

      GamePage.command(:leave_room, %{room_id: room.id}, server_for(creator))
      assert reload_room!(room).status == :ended
      assert reload_user!(creator).current_room_id == nil
    end
  end

  describe "client call sites send no identity" do
    setup %{room: room} do
      component = %Hologram.Component{
        props: %{room_id: room.id},
        state: %{
          current_user_id: "someone",
          current_user_username: "someone",
          is_creator: true,
          watching?: false,
          leaving?: false
        }
      }

      %{component: component}
    end

    test "join, resync, watch and leave only send the room id", %{component: c, room: room} do
      expected = %{room_id: room.id}

      mounted = %{c | state: Map.merge(c.state, mounted_state())}

      for {join, command} <- [player: :join_room, watcher: :join_as_watcher] do
        sent = GamePage.action(:mounted, %{join: join}, mounted).next_command
        assert {sent.name, sent.params} == {command, expected}
      end

      assert GamePage.action(:mounted, %{join: nil}, mounted).next_command == nil
      assert GamePage.action(:do_join_as_watcher, %{}, c).next_command.params == expected

      resync = GamePage.action(:command_denied, %{command: :x, reason: :y}, mounted).next_command

      assert {resync.name, resync.params} ==
               {:resync_room, Map.put(expected, :resubscribe, false)}

      leave = GamePage.action(:leave_room, %{}, c).next_command
      assert {leave.name, leave.params} == {:leave_room, expected}

      watching = put_in(c.state.watching?, true)
      leave_watch = GamePage.action(:leave_room, %{}, watching).next_command
      assert {leave_watch.name, leave_watch.params} == {:leave_watcher, expected}
    end

    test ":command_denied clears leaving? and resyncs", %{component: c} do
      leaving = %{c | state: Map.merge(c.state, %{mounted_state() | leaving?: true})}

      result =
        GamePage.action(:command_denied, %{command: :start_game, reason: :not_creator}, leaving)

      assert result.state.leaving? == false
      assert result.next_command.name == :resync_room
    end
  end

  # What :mounted and a resync request read besides the identity keys above.
  defp mounted_state do
    %{
      is_drawer: false,
      drawing_strokes: [],
      players: [],
      watchers: [],
      round_remaining_ms: 0,
      choice_remaining_ms: 0,
      choice_duration: 15,
      round_duration: 60,
      round_deadline_local: nil,
      choice_deadline_local: nil,
      zero_since: nil,
      time_left: 0,
      choice_time_left: 0,
      tick_gen: 1,
      last_tick_at: nil,
      phase_entered_at: nil,
      resync_requested_at: nil,
      leaving?: false
    }
  end
end
