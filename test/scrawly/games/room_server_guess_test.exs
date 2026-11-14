defmodule Scrawly.Games.RoomServerGuessTest do
  @moduledoc """
  Guesses and chat are checked inside the room process
  (`RoomServer.submit_message/3`), never trusted from the client.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.{Guess, RoomServer, Scoring}
  alias Scrawly.Games.RoomServer.GameFlow
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @word "zzyzx"
  @drawer "drawer-id"
  @p1 "p1-id"
  @p2 "p2-id"
  @watcher "watcher-id"

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp drawing_state(attrs \\ []) do
    struct!(
      %RoomServer{
        room_id: "TEST-room-#{System.unique_integer([:positive])}",
        status: :playing,
        creator_id: @drawer,
        max_players: 4,
        game_id: "TEST-game-#{System.unique_integer([:positive])}",
        phase: :drawing,
        current_round: 1,
        total_rounds: 3,
        current_drawer_id: @drawer,
        current_word: @word,
        round_active: true,
        time_left: 60,
        round_duration: 60,
        players: [
          %{id: @drawer, username: "Drawer", score: 0},
          %{id: @p1, username: "P1", score: 0},
          %{id: @p2, username: "P2", score: 0}
        ],
        watchers: [%{id: @watcher, username: "Watcher"}],
        round_start_scores: %{@drawer => 0, @p1 => 0, @p2 => 0}
      },
      attrs
    )
  end

  defp submit(state, uid, text) do
    {:reply, reply, new_state} =
      RoomServer.handle_call({:submit_message, uid, text}, {self(), make_ref()}, state)

    {reply, new_state}
  end

  defp subscribe(room_id) do
    Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room_id}))
  end

  defp score_of(state, id), do: Enum.find(state.players, &(&1.id == id)).score

  defp mentions_word?(text), do: String.contains?(String.downcase(text), @word)

  defp assert_unchanged(before, after_state) do
    assert after_state == before
  end

  # Fields a suppressed or rejected message must not touch.
  defp visible(state), do: Map.drop(Map.from_struct(state), [:chat_rate_limits])

  # ── Guess.matches?/2 ──────────────────────────────────────────────────────

  describe "Guess.matches?/2" do
    test "ignores case and surrounding whitespace" do
      assert Guess.matches?("  ZzYzX \n", @word)
      assert Guess.matches?(@word, "  ZZYZX ")
    end

    test "never matches nil or empty" do
      refute Guess.matches?("", "")
      refute Guess.matches?("   ", "  ")
      refute Guess.matches?(nil, @word)
      refute Guess.matches?(@word, nil)
      refute Guess.matches?("", @word)
      refute Guess.matches?(@word, "")
    end

    test "partial or containing text does not match" do
      refute Guess.matches?("zzy", @word)
      refute Guess.matches?("it is zzyzx", @word)
    end
  end

  # ── Rule matrix (handle_call on a struct) ─────────────────────────────────

  describe "a correct guess" do
    test "scores a non-drawer player once, without storing the word" do
      state = drawing_state()
      subscribe(state.room_id)

      {reply, new_state} = submit(state, @p1, "  ZZyzx  ")

      points = Scoring.guesser_points(60, 60, order: 1)
      assert reply == {:ok, {:correct, points}}
      assert new_state.correct_guessers == [@p1]
      assert new_state.round_guesser_points == [points]
      assert score_of(new_state, @p1) == points
      assert score_of(new_state, @p2) == 0
      assert score_of(new_state, @drawer) == 0
      assert new_state.phase == :drawing
      assert new_state.version == state.version + 1

      assert [line] = new_state.chat_messages
      assert line.type == :correct_guess
      assert line.message == "P1 guessed the word! (+#{points} points)"
      refute Enum.any?(new_state.chat_messages, &mentions_word?(&1.message))

      assert_received {:broadcast_action, _, :chat_appended, %{message: %{type: :correct_guess}},
                       _}

      assert_received {:broadcast_action, _, :room_delta, %{correct_guessers: [@p1]}, _}
      refute_received {:broadcast_action, _, :chat_appended, _, _}
    end

    test "the second guesser gets the 2nd-place order bonus" do
      {_, state} = submit(drawing_state(players: four_players()), @p1, @word)
      {reply, _} = submit(state, @p2, @word)

      assert reply == {:ok, {:correct, Scoring.guesser_points(60, 60, order: 2)}}
    end

    test "a repeat guess is suppressed: no points, no line, no broadcast" do
      {{:ok, {:correct, _}}, state} = submit(drawing_state(), @p1, @word)
      subscribe(state.room_id)

      {reply, new_state} = submit(state, @p1, " zzyzx")

      assert reply == {:ok, :suppressed}
      assert visible(new_state) == visible(state)
      refute_received {:broadcast_action, _, _, _, _}
    end

    test "a watcher typing the word is suppressed and never scores" do
      state = drawing_state()
      subscribe(state.room_id)

      {reply, new_state} = submit(state, @watcher, "ZZYZX")

      assert reply == {:ok, :suppressed}
      assert visible(new_state) == visible(state)
      assert new_state.correct_guessers == []
      refute_received {:broadcast_action, _, _, _, _}
    end

    test "the last guesser ends the round early and the drawer is scored" do
      {{:ok, {:correct, p1_pts}}, state} = submit(drawing_state(), @p1, @word)
      {{:ok, {:correct, p2_pts}}, state} = submit(state, @p2, @word)

      assert state.phase == :round_end
      assert state.round_active == false
      assert state.time_left == 0
      assert score_of(state, @drawer) == Scoring.drawer_round_points([p1_pts, p2_pts])
      assert [%{drawer_id: @drawer, word: @word}] = state.round_results

      # newest first: the correct-guess line precedes the round summary
      assert [summary, p2_line, p1_line] = state.chat_messages
      assert p1_line.type == :correct_guess
      assert p2_line.type == :correct_guess
      assert p2_line.message =~ "P2 guessed the word!"
      assert summary.type == :system
      assert summary.message =~ "Everyone guessed!"
    end
  end

  describe "other text" do
    test "is broadcast as :chat under the stored name" do
      state = drawing_state()
      subscribe(state.room_id)

      {reply, new_state} = submit(state, @p1, "  is it a zebra?  ")

      assert reply == {:ok, :chat}
      assert [msg] = new_state.chat_messages

      assert %{player_id: @p1, player_name: "P1", message: "is it a zebra?", type: :chat} =
               msg

      assert is_integer(msg.id) and msg.id > 0
      assert new_state.correct_guessers == []
      assert_received {:broadcast_action, _, :chat_appended, %{message: ^msg}, _}
    end

    test "watchers chat under their stored name" do
      {{:ok, :chat}, state} = submit(drawing_state(), @watcher, "hi all")
      assert [%{player_id: @watcher, player_name: "Watcher", type: :chat}] = state.chat_messages
    end

    test "is capped at 240 characters" do
      {{:ok, :chat}, state} = submit(drawing_state(), @p1, String.duplicate("a", 300))
      assert String.length(hd(state.chat_messages).message) == 240
    end

    test "outside :drawing the word is plain chat" do
      state = drawing_state(phase: :round_end, round_active: false)
      {reply, new_state} = submit(state, @p1, @word)

      assert reply == {:ok, :chat}
      assert new_state.correct_guessers == []
      assert score_of(new_state, @p1) == 0
    end

    test "chat history keeps the newest 50 lines" do
      old = for i <- 1..50, do: %{id: i, message: "old #{i}", type: :chat}
      {{:ok, :chat}, state} = submit(drawing_state(chat_messages: old), @p1, "new")

      assert length(state.chat_messages) == 50
      assert hd(state.chat_messages).message == "new"
    end
  end

  describe "rejections leave the state unchanged" do
    test "empty, blank or non-string text" do
      state = drawing_state()

      for text <- ["", "   \n ", nil, 42, %{text: "x"}, <<0xFF, 0xFE>>] do
        {reply, new_state} = submit(state, @p1, text)
        assert reply == {:error, :empty}
        assert_unchanged(state, new_state)
      end
    end

    test "the drawer while :choosing or :drawing" do
      for phase <- [:choosing, :drawing] do
        state = drawing_state(phase: phase)
        subscribe(state.room_id)

        for text <- [@word, "hint: it's striped"] do
          {reply, new_state} = submit(state, @drawer, text)
          assert reply == {:error, :drawer_cannot_chat}
          assert_unchanged(state, new_state)
        end

        refute_received {:broadcast_action, _, _, _, _}
      end
    end

    test "the drawer may chat once the round has ended" do
      state = drawing_state(phase: :round_end, round_active: false)
      assert {{:ok, :chat}, _} = submit(state, @drawer, "gg")
    end

    test "a non-member, or no user at all" do
      state = drawing_state()
      subscribe(state.room_id)

      for uid <- ["stranger", nil] do
        {reply, new_state} = submit(state, uid, @word)
        assert reply == {:error, :not_in_room}
        assert_unchanged(state, new_state)
      end

      refute_received {:broadcast_action, _, _, _, _}
    end

    test "a 4th message within 5 s from one user id, guesses included" do
      {{:ok, :chat}, state} = submit(drawing_state(), @p1, "one")
      {{:ok, :chat}, state} = submit(state, @p1, "two")
      {{:ok, {:correct, _}}, state} = submit(state, @p1, @word)

      {reply, new_state} = submit(state, @p1, "four")

      assert reply == {:error, :rate_limited}
      assert_unchanged(state, new_state)

      # other users are unaffected
      assert {{:ok, :chat}, _} = submit(state, @p2, "mine")
    end

    test "the window is 5 s" do
      now = System.monotonic_time(:millisecond)
      stale = %{@p1 => [now - 5_100, now - 6_000, now - 7_000]}

      {reply, state} = submit(drawing_state(chat_rate_limits: stale), @p1, "back again")

      assert reply == {:ok, :chat}
      assert [_fresh] = state.chat_rate_limits[@p1]
    end
  end

  describe "server-built lines" do
    test "add_sys_msg ids are unique and the type defaults to :system" do
      state = drawing_state()

      state =
        Enum.reduce(1..200, state, fn i, acc -> GameFlow.add_sys_msg(acc, "line #{i}") end)

      ids = Enum.map(state.chat_messages, & &1.id)
      assert length(Enum.uniq(ids)) == length(ids)
      assert Enum.all?(state.chat_messages, &(&1.type == :system))

      assert [%{type: :correct_guess}] =
               GameFlow.add_sys_msg(drawing_state(), "x", :correct_guess).chat_messages
    end

    test "system_message/2 posts a :system line" do
      creator = create_user()
      room = start_room(creator)

      assert RoomServer.system_message(room.id, "TEST AI generated 9/9 words") == :ok

      assert %{type: :system, player_name: "System"} =
               Enum.find(room_state!(room.id).chat_messages, &(&1.message =~ "TEST AI"))
    end

    test "the old entry points are gone" do
      refute function_exported?(RoomServer, :record_guess, 2)
      refute function_exported?(RoomServer, :send_chat_message, 2)
    end
  end

  # ── Live room process ─────────────────────────────────────────────────────

  describe "live room in :drawing" do
    setup :live_drawing_room

    test "a correct guess scores once and is broadcast without the word", ctx do
      %{room: room, guesser: guesser, other: other} = ctx
      subscribe(room.id)

      assert {:ok, {:correct, points}} = RoomServer.submit_message(room.id, guesser.id, "ZZYZX ")
      assert {:ok, :suppressed} = RoomServer.submit_message(room.id, guesser.id, @word)

      state = room_state!(room.id)
      assert state.correct_guessers == [guesser.id]
      assert score_of(state, guesser.id) == points
      assert score_of(state, other.id) == 0

      assert points in Scoring.guesser_points(0, 60, order: 1)..Scoring.guesser_points(60, 60,
               order: 1
             )

      refute Enum.any?(chat_texts(state), &mentions_word?/1)

      assert_receive {:broadcast_action, {:room, _}, :chat_appended,
                      %{message: %{type: :correct_guess, message: line}}, []}

      refute mentions_word?(line)
      refute_receive {:broadcast_action, _, :chat_appended, _, _}, 100
    end

    test "the drawer cannot chat, and a non-member is rejected", ctx do
      %{room: room, creator: creator} = ctx
      before = room_state!(room.id)

      assert RoomServer.submit_message(room.id, creator.id, @word) ==
               {:error, :drawer_cannot_chat}

      assert RoomServer.submit_message(room.id, "stranger", "hi") == {:error, :not_in_room}

      after_state = room_state!(room.id)
      assert after_state.chat_messages == before.chat_messages
      assert after_state.correct_guessers == []
    end

    test "an unknown room is :not_found" do
      assert RoomServer.submit_message(Ash.UUID.generate(), "x", "hi") == {:error, :not_found}
    end
  end

  defp four_players do
    [
      %{id: @drawer, username: "Drawer", score: 0},
      %{id: @p1, username: "P1", score: 0},
      %{id: @p2, username: "P2", score: 0},
      %{id: "p3-id", username: "P3", score: 0}
    ]
  end

  defp live_drawing_room(_ctx) do
    creator = create_user()
    guesser = create_user()
    other = create_user()
    room = start_room(creator)

    for user <- [guesser, other] do
      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
               :room_refreshed
    end

    {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: [@word, "TEST"]})
    on_exit(fn -> Scrawly.Games.stop_round_timer(started.game_id) end)
    {:ok, drawing} = RoomServer.choose_word(room.id, creator.id, @word)
    assert drawing.phase == :drawing
    assert drawing.current_drawer_id == creator.id

    %{room: room, creator: creator, guesser: guesser, other: other}
  end
end
