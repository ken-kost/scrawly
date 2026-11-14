defmodule Scrawly.Games.RoomServerLobbyTest do
  @moduledoc """
  The home page's room list as a room keeps it current: `lobby_summary/1`
  (only what RoomList renders), `list_lobby_rooms/0`, and the `:lobby`
  broadcasts (`:lobby_room_changed` while in the lobby, `:lobby_room_removed`
  otherwise), seen on Hologram.PubSub as the SSE connections see them.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.RoomServer

  @moduletag :capture_log

  @summary_keys [
    :code,
    :max_players,
    :name,
    :players,
    :room_id,
    :round_duration,
    :round_multiplier,
    :status,
    :word_source
  ]

  defp subscribe_lobby,
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(:lobby))

  # The lobby broadcasts about `room_id` received so far (other tests' rooms
  # may broadcast on the same channel).
  defp lobby_events(room_id, ms \\ 100, acc \\ []) do
    receive do
      {:broadcast_action, :lobby, :lobby_room_changed, %{room: %{room_id: ^room_id} = room}, []} ->
        lobby_events(room_id, ms, [{:changed, room} | acc])

      {:broadcast_action, :lobby, :lobby_room_removed, %{room_id: ^room_id}, []} ->
        lobby_events(room_id, ms, [:removed | acc])
    after
      ms -> Enum.reverse(acc)
    end
  end

  defp join!(room, user) do
    {:ok, _} =
      RoomServer.join(room.id, %{
        id: user.id,
        username: user.username,
        score: 0,
        avatar_id: "a3",
        avatar_color: "7"
      })
  end

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  setup do
    creator = create_user()
    player = create_user()
    %{creator: creator, player: player}
  end

  describe "lobby_summary/1" do
    test "has only what the room list shows; players are just avatars" do
      state = %RoomServer{
        room_id: "r1",
        name: "TEST room",
        code: "ABCD",
        status: :lobby,
        creator_id: "secret-creator",
        max_players: 6,
        word_source: :ai,
        prompt: "TEST secret prompt",
        round_duration: 120,
        round_multiplier: 2,
        players: [
          %{id: "u1", username: "TESTa", score: 9, avatar_id: "a1", avatar_color: "2"},
          %{id: "u2", username: "TESTb", score: 0}
        ],
        chat_messages: [%{id: 1, text: "TEST secret chat"}],
        past_games: [%{id: "g"}]
      }

      summary = RoomServer.lobby_summary(state)

      assert Map.keys(summary) |> Enum.sort() == @summary_keys

      assert summary == %{
               room_id: "r1",
               name: "TEST room",
               code: "ABCD",
               status: :lobby,
               max_players: 6,
               word_source: :ai,
               round_duration: 120,
               round_multiplier: 2,
               players: [
                 %{avatar_id: "a1", avatar_color: "2"},
                 %{avatar_id: nil, avatar_color: nil}
               ]
             }

      assert struct_free?(summary)
    end
  end

  describe "list_lobby_rooms/0" do
    test "the summaries of the running rooms that are in the lobby", ctx do
      lobby = start_room(ctx.creator, %{name: "TEST lobby room"})
      playing = start_room(ctx.player, %{name: "TEST playing room"})
      join!(playing, create_user())

      {:ok, started} =
        RoomServer.start_game(playing.id, ctx.player.id, %{word_choices: ["zzyzx"]})

      on_exit(fn -> Games.stop_round_timer(started.game_id) end)

      rooms = RoomServer.list_lobby_rooms()
      ids = Enum.map(rooms, & &1.room_id)

      assert lobby.id in ids
      refute playing.id in ids
      assert Enum.all?(rooms, &(Map.keys(&1) |> Enum.sort() == @summary_keys))

      assert %{name: "TEST lobby room", status: :lobby} =
               Enum.find(rooms, &(&1.room_id == lobby.id))
    end
  end

  describe ":lobby broadcasts" do
    test "a room announces itself when it starts in the lobby", ctx do
      subscribe_lobby()
      room = start_room(ctx.creator)

      assert [{:changed, summary}] = lobby_events(room.id)
      assert Map.keys(summary) |> Enum.sort() == @summary_keys
      assert length(summary.players) == 1
    end

    test "join and leave update the room's row", ctx do
      room = start_room(ctx.creator)
      subscribe_lobby()

      join!(room, ctx.player)

      assert [{:changed, %{players: [_, %{avatar_id: "a3", avatar_color: "7"}]}}] =
               lobby_events(room.id)

      {:ok, _} = RoomServer.leave(room.id, ctx.player.id)
      assert [{:changed, %{players: [_]}}] = lobby_events(room.id)

      # A rejected leave changes nothing.
      {:error, :not_member} = RoomServer.leave(room.id, ctx.player.id)
      assert lobby_events(room.id) == []
    end

    test "starting a game removes the row; the room comes back after the game", ctx do
      room = start_room(ctx.creator)
      join!(room, ctx.player)
      subscribe_lobby()

      {:ok, started} = RoomServer.start_game(room.id, ctx.creator.id, %{word_choices: ["zzyzx"]})
      on_exit(fn -> Games.stop_round_timer(started.game_id) end)
      assert lobby_events(room.id) == [:removed]

      {:ok, _} = RoomServer.end_game(room.id)
      assert lobby_events(room.id) == [:removed]

      send(pid_of(room), :return_to_lobby)
      assert [{:changed, %{status: :lobby, players: []}}] = lobby_events(room.id)
    end

    test "dissolving and the creator leaving remove the row", ctx do
      room = start_room(ctx.creator)
      subscribe_lobby()

      :ok = RoomServer.dissolve_room(room.id, ctx.creator.id)
      assert lobby_events(room.id) == [:removed]

      other = start_room(ctx.player)
      assert [{:changed, _}] = lobby_events(other.id)
      {:ok, :dissolved} = RoomServer.leave(other.id, ctx.player.id)
      assert lobby_events(other.id) == [:removed]
    end

    test "a room that stops itself or crashes removes the row", ctx do
      room = start_room(ctx.creator)
      other = start_room(ctx.player)
      subscribe_lobby()

      send(pid_of(room), :stop_self)
      assert lobby_events(room.id) == [:removed]

      :sys.terminate(pid_of(other), :boom)
      assert lobby_events(other.id) == [:removed]
    end
  end
end
