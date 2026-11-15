defmodule Scrawly.Games.RoomPresenceTest do
  @moduledoc """
  QA G9 / P3: watchers and lobby players without a live tab, and watch
  join/leave abuse.

    * Watching or no longer watching posts no chat line (the room's
      "watching" list shows who watches), so join/leave can't flood chat.
    * An actor (`ScrawlyWeb.Auth.actor_key/1`) gets 8 watch joins/leaves per
      minute in a room; the next join is refused with `:rate_limited`. A
      leave is never refused (and can't outnumber the joins).
    * The room sweeps its members against `ScrawlyWeb.OnlineTracker` (fed by
      every tab's layout heartbeat, keyed by actor key): a watcher, or a
      player while the room is in its lobby, whose key has been missing for
      `presence_grace_ms/0` (players: `player_presence_grace_ms/0`) is removed. Players are never removed mid-game
      (the round runs to its deadline, as before); the creator going away
      in the lobby dissolves the room, as their leaving does.

  The periodic sweep (`:presence_sweep`) is off in the test config; tests
  send `{:presence_sweep, now}` with their own monotonic `now`.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Accounts
  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.OnlineTracker
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  # The global tracker, as the layout's heartbeat leaves it. count/0 is a
  # call, ordered after this process's touch casts.
  defp live!(keys) do
    Enum.each(List.wrap(keys), &OnlineTracker.touch/1)
    OnlineTracker.count()
  end

  defp sweep!(room, now) do
    send(pid_of(room), {:presence_sweep, now})
    # Replies after the sweep (messages are handled in order).
    RoomServer.get_state(room.id)
  end

  defp key, do: "anon:TEST#{System.unique_integer([:positive])}"

  defp join!(room, user) do
    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
             :room_resynced
  end

  defp grace, do: RoomServer.presence_grace_ms()
  defp player_grace, do: RoomServer.player_presence_grace_ms()

  setup do
    creator = create_user()
    live!(creator.id)
    room = start_room(creator)
    %{room: room, creator: creator}
  end

  describe "watcher chat lines" do
    test "watching and leaving post no chat line", %{room: room} do
      before = room_state!(room.id).chat_messages
      w = key()

      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"})
      assert {:ok, _} = RoomServer.leave_watcher(room.id, w)

      assert room_state!(room.id).chat_messages == before
    end
  end

  describe "watch join/leave rate limit" do
    test "8 joins/leaves a minute per actor, then joins are refused; leaves never are",
         %{room: room} do
      {max, window} = RoomServer.watch_rate_limit()
      assert {max, window} == {8, 60_000}
      w = key()

      for _ <- 1..4 do
        assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"})
        assert {:ok, _} = RoomServer.leave_watcher(room.id, w)
      end

      assert RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"}) ==
               {:error, :rate_limited}

      refute Enum.any?(room_state!(room.id).watchers, &(&1.id == w))

      # Someone else is unaffected.
      other = key()
      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: other, username: "TESTo"})

      # A minute later the actor may watch again.
      :sys.replace_state(pid_of(room), fn state ->
        %{
          state
          | watch_rate_limits:
              Map.new(state.watch_rate_limits, fn {k, ts} ->
                {k, Enum.map(ts, &(&1 - window))}
              end)
        }
      end)

      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"})
    end

    test "a leave over the limit still leaves", %{room: room} do
      w = key()

      for _ <- 1..3 do
        assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"})
        assert {:ok, _} = RoomServer.leave_watcher(room.id, w)
      end

      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"})
      # 8th event: the budget is spent by the leave itself.
      assert {:ok, _} = RoomServer.leave_watcher(room.id, w)
      assert room_state!(room.id).watchers == []
    end

    test "the game page says why a watch join was refused", %{room: room} do
      server = anon_server("g9-rate-#{System.unique_integer([:positive])}")

      for _ <- 1..4 do
        GamePage.command(:join_as_watcher, %{room_id: room.id}, server)
        GamePage.command(:leave_watcher, %{room_id: room.id}, server)
      end

      result = GamePage.command(:join_as_watcher, %{room_id: room.id}, server)
      assert result.next_action.name == :command_denied
      assert result.next_action.params == %{command: :join_as_watcher, reason: :rate_limited}

      component = %Hologram.Component{
        state: %{
          join_notice: nil,
          leaving?: false,
          resync_requested_at: nil,
          last_seq: 1
        },
        props: %{room_id: room.id}
      }

      denied = GamePage.action(:command_denied, result.next_action.params, component)
      assert denied.state.join_notice =~ "try again in a minute"
    end
  end

  describe "watchers without a live tab" do
    test "are removed once missing from the tracker for the grace period; live ones stay",
         %{room: room} do
      gone = key()
      here = key()
      live!(here)

      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: gone, username: "TESTgone"})
      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: here, username: "TESThere"})

      t0 = System.monotonic_time(:millisecond)
      {:ok, state} = sweep!(room, t0)
      assert length(state.watchers) == 2

      {:ok, state} = sweep!(room, t0 + grace() - 1)
      assert length(state.watchers) == 2

      live!(here)
      {:ok, state} = sweep!(room, t0 + grace())
      assert Enum.map(state.watchers, & &1.id) == [here]
    end

    test "a key seen again starts its absence over", %{room: room} do
      w = key()
      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"})

      t0 = System.monotonic_time(:millisecond)
      sweep!(room, t0)
      live!(w)
      sweep!(room, t0 + 1_000)

      # Seen at t0 + 1 s, so missing for less than the grace period here.
      {:ok, state} = sweep!(room, t0 + grace())
      assert Enum.map(state.watchers, & &1.id) == [w]
    end

    test "are removed in any phase, quietly", %{room: room, creator: creator} do
      player = create_user()
      live!(player.id)
      join!(room, player)
      start_drawing!(room, creator)

      w = key()
      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"})
      chat = room_state!(room.id).chat_messages

      t0 = System.monotonic_time(:millisecond)
      sweep!(room, t0)
      {:ok, state} = sweep!(room, t0 + grace())

      assert state.watchers == []
      assert state.phase == :drawing
      assert state.chat_messages == chat
    end
  end

  describe "lobby players without a live tab" do
    test "are removed after the grace period, with their DB membership",
         %{room: room, creator: creator} do
      gone = create_user()
      here = create_user()
      live!(here.id)
      join!(room, gone)
      join!(room, here)

      Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(:lobby))

      t0 = System.monotonic_time(:millisecond)
      sweep!(room, t0)
      live!([creator.id, here.id])
      # A watcher's one-minute grace is not enough to drop a lobby player.
      {:ok, state} = sweep!(room, t0 + grace())
      assert Enum.any?(state.players, &(&1.id == gone.id))

      {:ok, state} = sweep!(room, t0 + player_grace())

      assert Enum.map(state.players, & &1.id) == [creator.id, here.id]
      assert reload_user!(gone).current_room_id == nil
      assert reload_user!(here).current_room_id == room.id
      assert Enum.any?(state.chat_messages, &(&1.message =~ "#{gone.username} left"))

      room_id = room.id

      assert_receive {:broadcast_action, :lobby, :lobby_room_changed,
                      %{room: %{room_id: ^room_id, players: players}}, _}

      assert length(players) == 2
    end

    test "a membership that moved to another room is left alone", %{room: room} do
      gone = create_user()
      join!(room, gone)

      other_creator = create_user()
      other = start_room(other_creator)
      {:ok, _} = Accounts.join_room(reload_user!(gone), other.id)

      t0 = System.monotonic_time(:millisecond)
      sweep!(room, t0)
      sweep!(room, t0 + player_grace())

      assert reload_user!(gone).current_room_id == other.id
    end

    test "are kept mid-game: the round runs to its deadline", %{room: room, creator: creator} do
      gone = create_user()
      join!(room, gone)
      start_drawing!(room, creator)

      t0 = System.monotonic_time(:millisecond)
      sweep!(room, t0)
      {:ok, state} = sweep!(room, t0 + player_grace() * 3)

      assert Enum.any?(state.players, &(&1.id == gone.id))
      assert state.phase == :drawing
    end

    test "the creator going away dissolves the room", %{room: room, creator: creator} do
      player = create_user()
      live!(player.id)
      # A creator the tracker never saw: their tab is gone.
      gone_creator = create_user()
      gone_room = start_room(gone_creator)
      join!(gone_room, player)

      t0 = System.monotonic_time(:millisecond)
      sweep!(gone_room, t0)
      ref = Process.monitor(pid_of(gone_room))
      send(pid_of(gone_room), {:presence_sweep, t0 + player_grace()})

      assert_receive {:DOWN, ^ref, :process, _, :normal}
      assert reload_room!(gone_room).status == :ended
      assert reload_user!(player).current_room_id == nil

      # The setup's room, whose creator is live, is untouched.
      sweep!(room, t0)
      {:ok, state} = sweep!(room, t0 + player_grace())
      assert state.status == :lobby
      assert Enum.any?(state.players, &(&1.id == creator.id))
    end
  end

  describe "the periodic sweep" do
    test "runs on its own when configured" do
      previous = Application.get_env(:scrawly, RoomServer)

      Application.put_env(:scrawly, RoomServer,
        presence_sweep_ms: 20,
        presence_grace_ms: 0,
        player_presence_grace_ms: 0
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:scrawly, RoomServer, previous),
          else: Application.delete_env(:scrawly, RoomServer)
      end)

      live_creator = create_user()
      live!(live_creator.id)
      room = start_room(live_creator)
      w = key()
      assert {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: w, username: "TESTw"})

      assert eventually(fn -> room_state!(room.id).watchers == [] end)
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
