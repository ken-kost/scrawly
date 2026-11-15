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

  doctest Guess

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
        round_deadline: System.monotonic_time(:millisecond) + 60_000,
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

    # {guess, word}: differ only in case, spacing, hyphens, apostrophes,
    # other punctuation or accents.
    @same_word [
      {"Zzyzx!", "zzyzx"},
      {"zzy zx", "zzyzx"},
      {"popcorn", "pop corn"},
      {"pop corn", "popcorn"},
      {"icecream", "ice cream"},
      {"ICE-CREAM!!", "ice cream"},
      {"ice  cream", "ice cream"},
      {"hot-dog", "hot dog"},
      {"hotdog", "hot dog"},
      {"tshirt", "t-shirt"},
      {"t shirt", "t-shirt"},
      {"T-Shirt?", "t-shirt"},
      {"jack o lantern", "jack-o'-lantern"},
      {"jackolantern", "jack-o'-lantern"},
      {"pigs ear", "pig's ear"},
      {"cafe", "café"},
      {"CAFÉ", "cafe"},
      {"crème brûlée", "creme brulee"},
      {"(ice) [cream]...", "ice cream"},
      {"  ice\tcream \n", "ice cream"}
    ]

    # {guess, word}: a missing or extra word, a typo, a plural, a prefix.
    @other_word [
      {"jack in box", "jack in the box"},
      {"it is ice cream", "ice cream"},
      {"ice cream cone", "ice cream"},
      {"icecreem", "ice cream"},
      {"ice creams", "ice cream"},
      {"ice", "ice cream"},
      {"pop", "popcorn"},
      {"hat", "what"},
      {"!!!", "!!!"},
      {"-", "t-shirt"}
    ]

    test "a guess that differs only in case, spacing, punctuation or accents matches" do
      for {guess, word} <- @same_word do
        assert Guess.matches?(guess, word), "#{inspect(guess)} should match #{inspect(word)}"
        assert Guess.matches?(word, guess), "#{inspect(word)} should match #{inspect(guess)}"
      end
    end

    test "a missing or extra word, a typo or a prefix does not match" do
      for {guess, word} <- @other_word do
        refute Guess.matches?(guess, word), "#{inspect(guess)} should not match #{inspect(word)}"
      end
    end

    test "whatever matches is also contained" do
      for {guess, word} <- @same_word do
        assert Guess.contains_word?(guess, word), inspect({guess, word})
      end
    end
  end

  describe "Guess.key/1" do
    test "lowercases, strips accents and drops spaces and punctuation" do
      assert Guess.key("Ice-Cream!") == "icecream"
      assert Guess.key(" ice  cream ") == "icecream"
      assert Guess.key("T-Shirt") == "tshirt"
      assert Guess.key("Jack-o'-lantern") == "jackolantern"
      assert Guess.key("Crème Brûlée") == "cremebrulee"
      assert Guess.key("route 66") == "route66"
    end

    test "is empty when there is no letter or digit, or the text is not UTF-8" do
      for text <- ["", "   ", "!?-", "'", <<0xFF, 0xFE>>] do
        assert Guess.key(text) == "", inspect(text)
      end
    end

    test "is idempotent" do
      for text <- ["Ice-Cream!", "café au lait", "jack-o'-lantern", "zzyzx"] do
        assert Guess.key(Guess.key(text)) == Guess.key(text)
      end
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
      # The :correct_guess line, then the :room_delta.
      assert new_state.seq == state.seq + 2

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
      assert state.round_deadline == nil
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

  # ── Lines that contain the word (QA G5) ───────────────────────────────────

  describe "Guess.contains_word?/2" do
    test "finds the word as a whole word, whatever the case, accents, punctuation or spacing" do
      for text <- ["Zzyzx!", "lol it is zzyzx", "it's ZZYZX.", "  zzyzx\t?? ", "(zzyzx)"] do
        assert Guess.contains_word?(text, @word), text
      end

      assert Guess.contains_word?("CAFE au lait", "café")
      assert Guess.contains_word?("un café !", "cafe")
      assert Guess.contains_word?("a HOT-dog please", "hot dog")
      assert Guess.contains_word?("hot   dog", "hot dog")
    end

    test "finds consecutive words that join into the word, and the word split into words" do
      for text <- [
            "is it icecream",
            "ice-cream?",
            "ICE  CREAM!!",
            "icecream",
            "i c e cream",
            "Ice/Cream, maybe",
            "oh, ice cream. yes"
          ] do
        assert Guess.contains_word?(text, "ice cream"), text
      end

      assert Guess.contains_word?("pop corn", "popcorn")
      assert Guess.contains_word?("a bag of POP-CORN", "popcorn")
      assert Guess.contains_word?("hotdog", "hot dog")
      assert Guess.contains_word?("zzy zx", @word)
      assert Guess.contains_word?("is it a jackolantern?", "jack-o'-lantern")
      assert Guess.contains_word?("it's a t shirt", "t-shirt")
    end

    test "a word inside another word, or a near miss, is not the word" do
      refute Guess.contains_word?("what is that", "hat")
      refute Guess.contains_word?("zzyzxx", @word)
      refute Guess.contains_word?("xzzyzx", @word)
      refute Guess.contains_word?("zzyz xx", @word)
      refute Guess.contains_word?("ice creams", "ice cream")
      refute Guess.contains_word?("nice cream", "ice cream")
      refute Guess.contains_word?("ice cold cream", "ice cream")
      refute Guess.contains_word?("cream ice", "ice cream")
      refute Guess.contains_word?("pop corny", "popcorn")
      refute Guess.contains_word?("jack in box", "jack in the box")
      refute Guess.contains_word?("zzyzx", nil)
      refute Guess.contains_word?(nil, @word)
      refute Guess.contains_word?("anything", "  ")
      refute Guess.contains_word?("anything", "?!")
    end

    test "checks every start, including runs that overlap a failed one" do
      # "a" + "aa" fails for "aab" at the first token, then "aa" + "b" spells it.
      assert Guess.contains_word?("a aa b", "aab")
      assert Guess.contains_word?("x a a a b", "aab")
      refute Guess.contains_word?("a a a", "aab")
    end

    test "handles a full 240-character line" do
      line = String.duplicate("a ", 120)
      assert String.length(line) == 240

      assert Guess.contains_word?(line, String.duplicate("a", 30))
      refute Guess.contains_word?(line, String.duplicate("a", 29) <> "b")
      refute Guess.contains_word?(line, String.duplicate("a", 121))
      assert Guess.contains_word?(line <> "b", "aab")
    end
  end

  describe "a line containing the word while :drawing" do
    test "from a player who hasn't guessed is suppressed, not scored and not stored" do
      for text <- ["lol it is zzyzx", "Zzyzx?? no way", "is it zzyzx?", "zz yzx or not"] do
        state = drawing_state()
        subscribe(state.room_id)

        {reply, new_state} = submit(state, @p1, text)

        assert reply == {:ok, :suppressed}, text
        assert visible(new_state) == visible(state)
        refute_received {:broadcast_action, _, _, _, _}
      end
    end

    test "from a player who already guessed or a watcher is suppressed" do
      {{:ok, {:correct, _}}, state} = submit(drawing_state(), @p1, @word)
      subscribe(state.room_id)

      for {uid, text} <- [{@p1, "yes, ZZYZX!!"}, {@watcher, "it's zzyzx."}] do
        {reply, new_state} = submit(state, uid, text)

        assert reply == {:ok, :suppressed}
        assert visible(new_state) == visible(state)
      end

      refute_received {:broadcast_action, _, _, _, _}
    end

    test "with accents and punctuation normalised" do
      state = drawing_state(current_word: "café")
      assert {{:ok, :suppressed}, _} = submit(state, @p1, "is it CAFE?")
      assert {{:ok, {:correct, _}}, _} = submit(state, @p1, " CAFÉ ")
      assert {{:ok, {:correct, _}}, _} = submit(state, @p1, "CAFE?")
    end

    test "with the words joined, or the word split, is suppressed" do
      for {word, text} <- [
            {"ice cream", "is it icecream?"},
            {"ice cream", "ice-cream maybe"},
            {"ice cream", "i think its ICE  CREAM!!"},
            {"popcorn", "pop corn?? or not"}
          ] do
        state = drawing_state(current_word: word)
        subscribe(state.room_id)

        {reply, new_state} = submit(state, @p1, text)

        assert reply == {:ok, :suppressed}, text
        assert visible(new_state) == visible(state)
        refute_received {:broadcast_action, _, _, _, _}
      end
    end

    test "text that only contains the word's letters inside another word is chat" do
      state = drawing_state(current_word: "hat")
      assert {{:ok, :chat}, _} = submit(state, @p1, "what is that?")
    end
  end

  describe "a guess that differs only in spacing, hyphens, punctuation or accents" do
    test "scores exactly like the exact word" do
      exact_points = Scoring.guesser_points(60, 60, order: 1)

      for {word, guess} <- [
            {"ice cream", "icecream"},
            {"ice cream", "ICE-CREAM!!"},
            {"popcorn", "pop corn"},
            {"t-shirt", "tshirt"},
            {"jack-o'-lantern", "Jack o lantern"},
            {@word, "Zzyzx!"}
          ] do
        state = drawing_state(current_word: word)
        subscribe(state.room_id)

        {reply, new_state} = submit(state, @p1, guess)

        assert reply == {:ok, {:correct, exact_points}}, guess
        assert new_state.correct_guessers == [@p1]
        assert score_of(new_state, @p1) == exact_points
        assert [%{type: :correct_guess}] = new_state.chat_messages
        refute Enum.any?(new_state.chat_messages, &(&1.message =~ guess))

        assert_received {:broadcast_action, _, :chat_appended,
                         %{message: %{type: :correct_guess}}, _}

        refute_received {:broadcast_action, _, :chat_appended, _, _}
      end
    end

    test "a missing word or a typo is plain chat" do
      state = drawing_state(current_word: "jack in the box")
      assert {{:ok, :chat}, _} = submit(state, @p1, "jack in box")

      state = drawing_state(current_word: "ice cream")
      assert {{:ok, :chat}, _} = submit(state, @p1, "icecreem")
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

    @tag word: "ice cream"
    test "the joined form scores, and a line containing it never reaches the room", ctx do
      %{room: room, guesser: guesser, other: other} = ctx
      subscribe(room.id)
      before = room_state!(room.id)

      assert {:ok, :suppressed} = RoomServer.submit_message(room.id, other.id, "is it icecream?")
      refute_receive {:broadcast_action, _, :chat_appended, _, _}, 100
      assert room_state!(room.id).chat_messages == before.chat_messages

      assert {:ok, {:correct, _points}} =
               RoomServer.submit_message(room.id, guesser.id, "icecream")

      state = room_state!(room.id)
      assert state.correct_guessers == [guesser.id]
      refute Enum.any?(chat_texts(state), &(&1 =~ ~r/ice\W*cream/i))

      assert_receive {:broadcast_action, {:room, _}, :chat_appended,
                      %{message: %{type: :correct_guess}}, []}
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

  defp live_drawing_room(ctx) do
    word = Map.get(ctx, :word, @word)
    creator = create_user()
    guesser = create_user()
    other = create_user()
    room = start_room(creator)

    for user <- [guesser, other] do
      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
               :room_resynced
    end

    {:ok, _started} = RoomServer.start_game(room.id, creator.id, %{word_choices: [word, "TEST"]})
    {:ok, drawing} = RoomServer.choose_word(room.id, creator.id, word)
    assert drawing.phase == :drawing
    assert drawing.current_drawer_id == creator.id

    %{room: room, creator: creator, guesser: guesser, other: other}
  end
end
