defmodule Scrawly.Games.RoomServerRobustnessTest do
  @moduledoc """
  Regression tests for the QA "game/realtime" findings (G1, G3, G4, G6, G7,
  G8, G10, G11, G12, G13, G15) against live rooms. Players join the way the
  game page joins them (room process + DB membership).
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.{Game, RoomServer, Scoring, WordList}
  alias Scrawly.Games.RoomServer.{GameFlow, View}
  alias ScrawlyWeb.Pages.{GamePage, GameScorePage}

  @moduletag :capture_log

  @stroke %{id: "s-1", path: "M 1 1 L 2 2", color: "#000000", width: 2}

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp state!(room), do: :sys.get_state(pid_of(room))

  defp join!(room, user) do
    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
             :room_resynced
  end

  defp leave!(room, user),
    do: GamePage.command(:leave_room, %{room_id: room.id}, server_for(user))

  # A lobby room with `n` players: the creator first, then n - 1 joiners.
  defp room_with(n, attrs \\ %{}) do
    creator = create_user()
    room = start_room(creator, Map.merge(%{max_players: max(4, n)}, attrs))

    others =
      for _ <- 2..n//1 do
        user = create_user()
        join!(room, user)
        user
      end

    {room, [creator | others]}
  end

  # What the room's own 3 s :auto_advance_round does, without the wait.
  defp advance!(room) do
    send(pid_of(room), :auto_advance_round)
    state!(room)
  end

  defp ids(players), do: Enum.map(players, & &1.id)

  defp score_of(state, user), do: Enum.find(state.players, &(&1.id == user.id)).score

  defp subscribe(channel),
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))

  defp await(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(50) && await(fun, tries - 1)
    end
  end

  defp builtin_words(word_count) do
    for %{text: text} <- WordList.entries(), length(String.split(text)) == word_count, do: text
  end

  # ── G1 ────────────────────────────────────────────────────────────────────

  describe "G1: every room setting the home page offers can start a game" do
    test "total_rounds/2 stays within Game's cap and gives everyone the same number of turns" do
      for players <- 2..12, multiplier <- [1, 2, 3, 5] do
        total = RoomServer.total_rounds(players, multiplier)

        assert total <= Game.max_total_rounds()
        assert total >= players
        assert total <= players * multiplier
        assert rem(total, players) == 0
      end

      assert Game.max_total_rounds() == 24
      assert RoomServer.total_rounds(3, 5) == 15
      assert RoomServer.total_rounds(5, 3) == 15
      assert RoomServer.total_rounds(7, 2) == 14
      assert RoomServer.total_rounds(7, 5) == 21
      assert RoomServer.total_rounds(12, 5) == 24
    end

    test "the combinations that used to be refused start" do
      for {players, multiplier} <- [{3, 5}, {5, 3}, {7, 2}, {12, 5}] do
        {room, [creator | _]} =
          room_with(players, %{max_players: 12, round_multiplier: multiplier})

        assert {:ok, state} =
                 RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"]})

        expected = RoomServer.total_rounds(players, multiplier)
        assert state.total_rounds == expected
        assert [%{total_rounds: ^expected, status: :in_progress}] = games_for_room(room)
      end
    end
  end

  # ── G3 ────────────────────────────────────────────────────────────────────

  describe "G3: a room restarted mid-game" do
    test "returns to the lobby, cancels the stale Game and says why" do
      {room, [creator, player]} = room_with(2)
      {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"]})

      kill_room!(room)
      assert reload_room!(room).status == :playing

      assert {:ok, _pid} = RoomServer.ensure_started(room.id)

      state = room_state!(room.id)
      assert %{status: :lobby, game_id: nil, phase: :idle} = state
      assert Enum.sort(ids(state.players)) == Enum.sort([creator.id, player.id])
      assert Enum.any?(chat_texts(state), &(&1 =~ "interrupted"))
      assert reload_room!(room).status == :lobby
      assert Games.get_game_by_id!(started.game_id).status == :cancelled

      # Nothing is stuck: the creator can start again.
      assert {:ok, %{status: :playing}} =
               RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"]})
    end
  end

  # ── G4 ────────────────────────────────────────────────────────────────────

  describe "G4: a dissolved room can't be resurrected" do
    test "dissolve_room persists :ended before the process stops" do
      {room, [creator, player]} = room_with(2)

      assert :ok = RoomServer.dissolve_room(room.id, creator.id)

      # No Games.dissolve_room/1 from a command: the room process wrote it.
      assert reload_room!(room).status == :ended
      assert reload_user!(player).current_room_id == nil
      assert_room_unregistered(room.id)
      assert RoomServer.ensure_started(room.id) == {:error, :room_ended}
    end

    test "the creator leaving persists :ended before the process stops" do
      {room, [creator, _player]} = room_with(2)

      assert {:ok, :dissolved} = RoomServer.leave(room.id, creator.id)

      assert reload_room!(room).status == :ended
      assert_room_unregistered(room.id)
      assert RoomServer.ensure_started(room.id) == {:error, :room_ended}
    end
  end

  # ── G6 ────────────────────────────────────────────────────────────────────

  describe "G6: word choices never run out" do
    test "with no words in the DB the built-in list fills the choices" do
      assert Games.get_word_count() == 0

      for word_count <- 1..3 do
        builtin = builtin_words(word_count)
        {choices, [], 0} = GameFlow.pick_word_choices([], [], word_count, 3)

        assert length(choices) == 3
        assert Enum.uniq(choices) == choices
        assert Enum.all?(choices, &(&1 in builtin))

        assert {:ok, word} = Games.get_random_word(word_count: word_count)
        assert word in builtin
      end
    end

    test "a game started without choices gets three, and so does the next round" do
      {room, [creator, player]} = room_with(2)

      {:ok, _} = RoomServer.start_game(room.id, creator.id, %{})
      assert {:ok, %{word_choices: [first, _, _]}} = RoomServer.get_view(room.id, creator.id)

      {:ok, _} = RoomServer.choose_word(room.id, creator.id, first)
      assert expire_round!(room).phase == :round_end
      advance!(room)

      assert {:ok, %{current_round: 2, is_drawer: true, word_choices: [_, _, _]}} =
               RoomServer.get_view(room.id, player.id)
    end

    test "a turn with nothing to choose ends the game instead of freezing" do
      {room, [creator, _player]} = room_with(2)
      {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"]})

      :sys.replace_state(pid_of(room), &%{&1 | word_choices: []})
      send(pid_of(room), {:word_choice_timeout, started.game_id, 1})

      state = room_state!(room.id)
      assert state.status == :post_game
      assert state.last_game_id == started.game_id
      assert Enum.any?(chat_texts(state), &(&1 =~ "No word could be picked"))
    end

    test "a round transition that fails ends the game cleanly" do
      {room, [creator, _player]} = room_with(2)
      %{game_id: game_id} = start_drawing!(room, creator)
      assert expire_round!(room).phase == :round_end

      # The next round's DB writes fail: the Game row is gone.
      game_id |> Games.get_game_by_id!() |> Ash.destroy!()
      advance!(room)

      state = room_state!(room.id)
      assert state.status == :post_game
      assert Enum.any?(chat_texts(state), &(&1 =~ "next round couldn't start"))
    end
  end

  # ── G7 ────────────────────────────────────────────────────────────────────

  describe "G7: the AI refill never blocks the room" do
    test "the refill runs in its own process" do
      {room, [creator, _player]} =
        room_with(2, %{word_source: :ai, prompt: "TEST ocean animals"})

      {:ok, _} =
        RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"], ai_words: []})

      room_pid = pid_of(room)
      test_pid = self()
      handler = "slow-ai-#{System.unique_integer([:positive])}"

      # Stands in for a slow AI call, then kills the process running it, so
      # nothing reaches the network.
      :telemetry.attach(
        handler,
        [:ash, :games, :action, :start],
        fn _event, _measurements, _meta, _config ->
          send(test_pid, {:ai_call_in, self()})
          Process.sleep(600)
          Process.exit(self(), :kill)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      send(room_pid, {:refill_ai_words, room.id, 1, 2, :fun})
      assert_receive {:ai_call_in, worker}, 1_000
      refute worker == room_pid

      {elapsed, reply} = :timer.tc(fn -> RoomServer.get_state(room.id) end, :millisecond)
      assert {:ok, %{status: :playing}} = reply
      assert elapsed < 300

      ref = Process.monitor(worker)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
      assert Process.alive?(room_pid)
      assert state!(room).ai_refill == nil
    end

    test "the refill's words are merged when they come back" do
      {room, [creator, _player]} =
        room_with(2, %{word_source: :ai, prompt: "TEST ocean animals"})

      {:ok, started} =
        RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"], ai_words: ["old"]})

      ref = make_ref()
      :sys.replace_state(pid_of(room), &%{&1 | ai_refill: {ref, started.game_id}})
      send(pid_of(room), {ref, {:ok, ["new one", "old"]}})

      state = state!(room)
      assert state.ai_refill == nil
      assert Enum.sort(state.ai_words) == ["new one", "old"]
    end

    test "list_lobby_rooms/0 doesn't wait on a busy room" do
      {room, _players} = room_with(1)
      pid = pid_of(room)
      :sys.suspend(pid)

      {elapsed, rooms} = :timer.tc(&RoomServer.list_lobby_rooms/0, :millisecond)
      :sys.resume(pid)

      assert elapsed < 500
      assert Enum.any?(rooms, &(&1.room_id == room.id))
    end
  end

  # ── G8 ────────────────────────────────────────────────────────────────────

  describe "G8: leaving mid-game" do
    setup do
      {room, [a, b, c]} = room_with(3)
      %{room: room, a: a, b: b, c: c}
    end

    # Round 1 (A, the creator, draws) times out; round 2: B is choosing.
    defp to_round_two!(ctx) do
      start_drawing!(ctx.room, ctx.a)
      assert expire_round!(ctx.room).phase == :round_end
      state = advance!(ctx.room)
      assert %{current_round: 2, phase: :choosing} = state
      assert state.current_drawer_id == ctx.b.id
      state
    end

    test "the drawer leaving while drawing ends the turn and the next player draws", ctx do
      %{room: room, a: a, b: b, c: c} = ctx
      word = hd(to_round_two!(ctx).word_choices)
      {:ok, %{phase: :drawing}} = RoomServer.choose_word(room.id, b.id, word)

      leave!(room, b)

      state = room_state!(room.id)
      assert state.phase == :round_end
      assert state.revealed_word == word
      refute b.id in ids(state.players)
      assert Enum.any?(chat_texts(state), &(&1 =~ word))
      assert score_of(state, a) == 0 and score_of(state, c) == 0

      next = advance!(room)
      assert %{current_round: 3, phase: :choosing} = next
      assert next.current_drawer_id == c.id
    end

    test "the drawer leaving while choosing skips the turn", ctx do
      %{room: room, b: b, c: c} = ctx
      to_round_two!(ctx)

      leave!(room, b)

      state = room_state!(room.id)
      assert state.phase == :round_end
      assert state.revealed_word == nil
      assert Enum.any?(chat_texts(state), &(&1 =~ "skipped"))

      assert advance!(room).current_drawer_id == c.id
    end

    test "a guesser leaving ends the round once everyone left has guessed", ctx do
      %{room: room, a: a, b: b, c: c} = ctx
      start_drawing!(room, a)
      {:ok, {:correct, points}} = RoomServer.submit_message(room.id, b.id, "zzyzx")
      assert room_state!(room.id).phase == :drawing

      leave!(room, c)

      state = room_state!(room.id)
      assert state.phase == :round_end
      assert score_of(state, a) == Scoring.drawer_round_points([points])
      assert hd(state.chat_messages).message =~ "Everyone guessed!"
    end

    test "nobody is skipped or draws twice: a leaver's turns are dropped", ctx do
      %{room: room, a: a, b: b, c: c} = ctx
      start_drawing!(room, a)

      leave!(room, c)
      assert room_state!(room.id).total_rounds == 2

      assert expire_round!(room).phase == :round_end
      round_two = advance!(room)
      assert round_two.current_drawer_id == b.id

      {:ok, _} = RoomServer.choose_word(room.id, b.id, hd(round_two.word_choices))
      assert expire_round!(room).phase == :round_end
      advance!(room)

      assert room_state!(room.id).status == :post_game
    end

    test "a departed drawer can't draw and never gets the word", ctx do
      %{room: room, b: b} = ctx
      word = hd(to_round_two!(ctx).word_choices)
      {:ok, _} = RoomServer.choose_word(room.id, b.id, word)

      leave!(room, b)

      assert RoomServer.append_drawing(room.id, b.id, @stroke) == {:error, :not_drawer}
      refute RoomServer.drawing_allowed?(room.id, b.id)
      assert RoomServer.get_private_slice(room.id, b.id) == {:error, :not_drawer}

      assert {:ok, %{is_drawer: false, current_word: nil, word_choices: []}} =
               RoomServer.get_view(room.id, b.id)
    end

    test "authorize(:draw) and the drawer's view require current membership" do
      state = %RoomServer{
        current_drawer_id: "gone",
        phase: :choosing,
        current_word: "zzyzx",
        word_choices: ["zzyzx"],
        players: [%{id: "a", username: "A"}]
      }

      assert RoomServer.authorize(%{state | phase: :drawing}, "gone", :draw) ==
               {:error, :not_drawer}

      assert %{is_drawer: false, current_word: nil, word_choices: []} =
               View.for_viewer(state, "gone")
    end

    test "with fewer than 2 players left the game ends the normal way" do
      {room, [a, b]} = room_with(2)
      %{game_id: game_id} = start_drawing!(room, a)

      leave!(room, b)

      state = room_state!(room.id)
      assert state.status == :post_game
      assert state.last_game_id == game_id
      assert reload_room!(room).status == :post_game
      assert Games.get_game_by_id!(game_id).status == :completed
    end
  end

  # ── G10 ───────────────────────────────────────────────────────────────────

  describe "G10: after a game the room stays joinable" do
    defp finish_game!(room, creator) do
      {:ok, _} = RoomServer.start_game(room.id, creator.id, %{word_choices: ["zzyzx"]})
      {:ok, %{status: :post_game}} = RoomServer.end_game(room.id)
    end

    test "the players still in the room stay, and newcomers can join" do
      {room, [a, b]} = room_with(2)
      finish_game!(room, a)

      send(pid_of(room), :return_to_lobby)

      state = room_state!(room.id)
      assert state.status == :lobby
      assert ids(state.players) == [a.id, b.id]
      assert Enum.any?(RoomServer.list_lobby_rooms(), &(&1.room_id == room.id))

      newcomer = create_user()
      join!(room, newcomer)
      assert newcomer.id in ids(room_state!(room.id).players)
    end

    test "leavers and players who moved on are gone; stale memberships are cleared" do
      {room, [a, b, c]} = room_with(3)
      finish_game!(room, a)

      # b leaves from the score page; c moves on to another room.
      GameScorePage.command(:leave_room, %{room_id: room.id}, server_for(b))
      other = start_room(create_user())
      Accounts.join_room!(c, other.id)
      # An account pointing at this room without being in it.
      ghost = create_user()
      Accounts.join_room!(ghost, room.id)

      send(pid_of(room), :return_to_lobby)

      assert ids(room_state!(room.id).players) == [a.id]
      assert reload_user!(ghost).current_room_id == nil
      assert reload_user!(c).current_room_id == other.id
      assert reload_user!(a).current_room_id == room.id
    end

    test "a room whose creator moved on is dissolved instead of listed" do
      {room, [a, b]} = room_with(2)
      finish_game!(room, a)
      other = start_room(create_user())
      Accounts.join_room!(a, other.id)
      ref = Process.monitor(pid_of(room))

      send(pid_of(room), :return_to_lobby)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
      assert reload_room!(room).status == :ended
      assert reload_user!(b).current_room_id == nil
      refute Enum.any?(RoomServer.list_lobby_rooms(), &(&1.room_id == room.id))
    end

    test "a refused join replies :command_denied with the reason" do
      {room, [a, _b]} = room_with(2)
      {:ok, _} = RoomServer.start_game(room.id, a.id, %{word_choices: ["zzyzx"]})

      result = GamePage.command(:join_room, %{room_id: room.id}, server_for(create_user()))

      assert result.next_action.name == :command_denied
      assert result.next_action.params.command == :join_room
      assert result.next_action.params.reason == :not_in_lobby
    end
  end

  # ── G11 ───────────────────────────────────────────────────────────────────

  describe "G11: rounds time out from the room itself" do
    test "a RoundTimer restart can't stall a round" do
      {room, [a, _b]} = room_with(2)
      {:ok, _} = RoomServer.start_game(room.id, a.id, %{word_choices: ["zzyzx"]})
      :sys.replace_state(pid_of(room), &%{&1 | round_duration: 1})
      {:ok, %{phase: :drawing}} = RoomServer.choose_word(room.id, a.id, "zzyzx")

      # What a crash of the old global RoundTimer did: its timers were lost.
      if pid = Process.whereis(Scrawly.Games.RoundTimer), do: Process.exit(pid, :kill)

      await(fn -> room_state!(room.id).phase == :round_end end)
      assert room_state!(room.id).revealed_word == "zzyzx"
    end
  end

  # ── G12 ───────────────────────────────────────────────────────────────────

  describe "G12: ending or dissolving a game closes it" do
    test "dissolving mid-game cancels the Game row and its timers" do
      {room, [a, _b]} = room_with(2)
      %{game_id: game_id} = start_drawing!(room, a)
      refs = state!(room).turn_timers
      assert refs != []

      :ok = RoomServer.dissolve_room(room.id, a.id)

      assert Games.get_game_by_id!(game_id).status == :cancelled
      assert Enum.all?(refs, &(Process.read_timer(&1) == false))
    end

    test "the creator leaving mid-game cancels the Game row" do
      {room, [a, _b]} = room_with(2)
      %{game_id: game_id} = start_drawing!(room, a)

      leave!(room, a)

      assert Games.get_game_by_id!(game_id).status == :cancelled
      assert reload_room!(room).status == :ended
    end

    test "end_game completes the Game row and cancels the turn's timers" do
      {room, [a, _b]} = room_with(2)
      %{game_id: game_id} = start_drawing!(room, a)
      refs = state!(room).turn_timers
      assert refs != []

      {:ok, _} = RoomServer.end_game(room.id)

      assert Games.get_game_by_id!(game_id).status == :completed
      assert Enum.all?(refs, &(Process.read_timer(&1) == false))
      assert state!(room).turn_timers == []
    end
  end

  # ── G13 ───────────────────────────────────────────────────────────────────

  describe "G13: past games" do
    test "are capped and only sent in snapshots" do
      {room, [a, _b]} = room_with(2)
      old = for n <- 1..10, do: %{game_id: "g#{n}", total_rounds: 2, players: [], winner: nil}
      :sys.replace_state(pid_of(room), &%{&1 | past_games: old})
      {:ok, started} = RoomServer.start_game(room.id, a.id, %{word_choices: ["zzyzx"]})
      subscribe({:room, room.id})

      {:ok, _} = RoomServer.end_game(room.id)

      state = room_state!(room.id)
      assert length(state.past_games) == GameFlow.max_past_games()
      assert hd(state.past_games).game_id == started.game_id

      assert_receive {:broadcast_action, _, :room_delta, delta, _}
      refute Map.has_key?(delta, :past_games)
      refute Map.has_key?(View.delta(%RoomServer{}), :past_games)
    end
  end

  # ── G15 ───────────────────────────────────────────────────────────────────

  describe "G15: account scores" do
    defp guess!(room, user, text \\ "zzyzx") do
      result = GamePage.command(:submit_guess, %{room_id: room.id, text: text}, server_for(user))
      assert %{outcome: :correct, points: points} = result.next_action.params
      points
    end

    test "the drawer's points are persisted when everyone guessed" do
      {room, [a, b]} = room_with(2)
      start_drawing!(room, a)

      points = guess!(room, b)

      assert room_state!(room.id).phase == :round_end
      assert reload_user!(a).score == Scoring.drawer_round_points([points])
      assert reload_user!(b).score == points
    end

    test "the drawer's points are persisted at time up" do
      {room, [a, b, _c]} = room_with(3)
      start_drawing!(room, a)
      points = guess!(room, b)

      assert expire_round!(room).phase == :round_end
      assert reload_user!(a).score == Scoring.drawer_round_points([points])
    end

    test "User.score resets at game start and on joining a room" do
      {room, [a, b]} = room_with(2)
      Accounts.add_score!(a.id, 10)
      Accounts.add_score!(b.id, 40)

      {:ok, _} = RoomServer.start_game(room.id, a.id, %{word_choices: ["zzyzx"]})

      assert reload_user!(a).score == 0
      assert reload_user!(b).score == 0

      newcomer = create_user()
      Accounts.add_score!(newcomer.id, 70)
      {other, _} = room_with(1)
      join!(other, newcomer)

      assert reload_user!(newcomer).score == 0
      assert score_of(room_state!(other.id), newcomer) == 0
    end

    test "back in the lobby, the room's scores are the accounts' scores" do
      {room, [a, b]} = room_with(2)
      start_drawing!(room, a)
      guess!(room, b)
      {:ok, _} = RoomServer.end_game(room.id)
      send(pid_of(room), :return_to_lobby)

      state = room_state!(room.id)

      for user <- [a, b] do
        assert score_of(state, user) == reload_user!(user).score
      end

      assert score_of(state, b) > 0
    end
  end
end
