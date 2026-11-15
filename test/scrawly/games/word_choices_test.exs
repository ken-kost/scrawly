defmodule Scrawly.Games.WordChoicesTest do
  @moduledoc """
  A room's answer kind holds for every set of choices its drawers see:
  Words rooms never offer a phrase, Phrases rooms never offer a word, and
  every Mixed set has exactly one phrase. Checked for the curated words, the
  built-in fallback, the AI's (`Scrawly.FakeAiModel` replies like a model
  that ignores the rule), refills, and a room restored after a restart.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.{FakeAiModel, Games}
  alias Scrawly.Games.{AiWords, AnswerKind, RoomServer}
  alias Scrawly.Games.RoomServer.GameFlow
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @sets 60

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp phrases_in(choices), do: Enum.count(choices, &(AnswerKind.of(&1) == :phrase))

  defp assert_kind(:words, choices) do
    assert length(choices) == 3 and phrases_in(choices) == 0, "#{inspect(choices)}"
  end

  defp assert_kind(:phrases, choices) do
    assert length(choices) == 3 and phrases_in(choices) == 3, "#{inspect(choices)}"
  end

  defp assert_kind(:mixed, choices) do
    assert length(choices) == 3 and phrases_in(choices) == 1, "#{inspect(choices)}"
  end

  # `@sets` turns of a game, as the room plays them: the drawer takes the
  # first choice, the rest of the AI pool carries over. Returns the sets.
  defp play_turns(answer_kind, ai_pool) do
    {sets, _} =
      Enum.map_reduce(1..@sets, {ai_pool, []}, fn _turn, {pool, used} ->
        {choices, pool, _from_ai} = GameFlow.pick_word_choices(pool, used, answer_kind, 3)
        assert_kind(answer_kind, choices)
        assert Enum.uniq(choices) == choices
        assert Enum.all?(pool, &AnswerKind.allows?(answer_kind, &1))
        {choices, {pool, [hd(choices) | used]}}
      end)

    sets
  end

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp state!(room), do: :sys.get_state(pid_of(room))

  defp join!(room, user) do
    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
             :room_resynced
  end

  defp room_with_player(attrs) do
    creator = create_user()
    player = create_user()
    room = start_room(creator, Map.merge(%{max_players: 4, round_multiplier: 5}, attrs))
    join!(room, player)
    {room, creator, player}
  end

  defp drawer_choices(room) do
    state = state!(room)
    assert state.phase == :choosing
    state.word_choices
  end

  # Picks the first choice, ends the round and starts the next turn.
  defp next_turn!(room) do
    state = state!(room)
    {:ok, _} = RoomServer.choose_word(room.id, state.current_drawer_id, hd(state.word_choices))
    assert expire_round!(room).phase == :round_end
    send(pid_of(room), :auto_advance_round)
    state!(room)
  end

  defp await(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(50) && await(fun, tries - 1)
    end
  end

  # ── Choices ───────────────────────────────────────────────────────────────

  describe "with the curated words" do
    setup do
      Games.sync_words()
      :ok
    end

    for answer_kind <- [:words, :phrases, :mixed] do
      test "#{answer_kind}: #{@sets} sets of choices all follow the kind" do
        sets = play_turns(unquote(answer_kind), [])
        assert sets |> List.flatten() |> Enum.uniq() |> length() > 100
      end
    end

    test "phrases of two, three and four words are all offered" do
      lengths =
        for _ <- 1..@sets, word <- elem(GameFlow.pick_word_choices([], [], :phrases, 3), 0) do
          length(String.split(word))
        end

      assert Enum.sort(Enum.uniq(lengths)) == [2, 3, 4]
    end

    test "mixed puts the phrase at every position" do
      positions =
        for _ <- 1..@sets do
          {choices, _, _} = GameFlow.pick_word_choices([], [], :mixed, 3)
          Enum.find_index(choices, &(AnswerKind.of(&1) == :phrase))
        end

      assert Enum.sort(Enum.uniq(positions)) == [0, 1, 2]
    end
  end

  describe "with the built-in fallback" do
    test "an empty words table still gives every kind its choices" do
      assert Games.get_word_count() == 0
      for answer_kind <- AnswerKind.all(), do: play_turns(answer_kind, [])
    end

    test "a table of single words only still gives phrase rooms phrases" do
      seed_test_words()
      for answer_kind <- AnswerKind.all(), do: play_turns(answer_kind, [])
    end

    # Every word the table offers has the AI word's key.
    test "a set never holds two answers with one guess key" do
      for {text, difficulty} <- [{"testcat", :easy}, {"test-cat", :medium}, {"testcat'", :hard}] do
        Games.create_word!(%{text: text, difficulty: difficulty})
      end

      for _ <- 1..10 do
        {choices, [], 1} = GameFlow.pick_word_choices(["Test'Cat"], [], :words, 3)
        assert [_, _, _] = choices
        assert hd(choices) == "test'cat"
        assert choices |> Enum.map(&Scrawly.Games.Guess.key/1) |> Enum.uniq() |> length() == 3
      end
    end
  end

  describe "with AI words" do
    setup do
      Games.sync_words()
      :ok
    end

    for answer_kind <- [:words, :phrases, :mixed] do
      test "#{answer_kind}: a reply that ignores the rule never breaks it" do
        answer_kind = unquote(answer_kind)

        # Straight from the model, and as the action returns it.
        for pool <- [FakeAiModel.reply(), AiWords.filter(FakeAiModel.reply(), answer_kind)] do
          sets = play_turns(answer_kind, pool)
          offered = List.flatten(sets)

          # The AI's entries are offered first, then the curated words.
          assert Enum.any?(
                   offered,
                   &(&1 in (FakeAiModel.clean_words() ++ FakeAiModel.clean_phrases()))
                 )
        end
      end
    end

    test "in mixed, the AI's phrase fills the phrase slot and its words the others" do
      pool = AiWords.filter(FakeAiModel.reply(), :mixed)

      {choices, remaining, 3} = GameFlow.pick_word_choices(pool, [], :mixed, 3)
      assert_kind(:mixed, choices)
      assert Enum.all?(choices, &(&1 in pool))
      assert length(remaining) == length(pool) - 3

      # Only phrases left: the words come from the curated list.
      phrases = FakeAiModel.clean_phrases()
      {choices, remaining, 1} = GameFlow.pick_word_choices(phrases, [], :mixed, 3)
      assert_kind(:mixed, choices)
      assert [phrase] = Enum.filter(choices, &(&1 in phrases))
      assert remaining == phrases -- [phrase]
    end

    test "words already played are not offered again, whatever their spelling" do
      {choices, remaining, 1} =
        GameFlow.pick_word_choices(["test lagoon", "beach ball"], ["Test-Lagoon!"], :phrases, 3)

      refute "test lagoon" in choices
      assert "beach ball" in choices
      assert remaining == []
    end

    test "the pool keeps nothing the room can't offer" do
      {_choices, remaining, _} = GameFlow.pick_word_choices(FakeAiModel.reply(), [], :phrases, 3)
      assert remaining != []
      assert Enum.all?(remaining, &(AnswerKind.of(&1) == :phrase))

      {_choices, remaining, _} = GameFlow.pick_word_choices(FakeAiModel.reply(), [], :words, 3)
      assert Enum.all?(remaining, &(AnswerKind.of(&1) == :word))
    end
  end

  # ── Live rooms ────────────────────────────────────────────────────────────

  describe "an AI phrases room" do
    setup do
      Games.sync_words()
      :ok
    end

    test "never shows its drawer a single word, from start to refill" do
      {room, creator, _player} =
        room_with_player(%{answer_kind: :phrases, word_source: :ai, prompt: "TEST ocean"})

      # The start makes the AI call (FakeAiModel: words and phrases mixed).
      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      state = state!(room)
      assert state.status == :playing
      assert_kind(:phrases, drawer_choices(room))
      assert Enum.all?(drawer_choices(room), &(&1 in FakeAiModel.clean_phrases()))
      assert state.ai_words != []
      assert Enum.all?(state.ai_words, &(AnswerKind.of(&1) == :phrase))

      assert Enum.any?(
               state.chat_messages,
               &(&1.message == "phrases ready: 14 from your theme")
             )

      # Every later turn, as the pool runs low and refills come back.
      for _turn <- 2..8 do
        next = next_turn!(room)
        assert next.phase == :choosing
        assert_kind(:phrases, next.word_choices)
        await(fn -> state!(room).ai_refill == nil end)
        assert Enum.all?(state!(room).ai_words, &(AnswerKind.of(&1) == :phrase))
      end
    end

    test "a refill's words are dropped, even if the reply is all words" do
      {room, creator, _player} =
        room_with_player(%{answer_kind: :phrases, word_source: :ai, prompt: "TEST ocean"})

      {:ok, started} =
        RoomServer.start_game(room.id, creator.id, %{word_choices: ["sea turtle"], ai_words: []})

      ref = make_ref()
      :sys.replace_state(pid_of(room), &%{&1 | ai_refill: {ref, started.game_id}})
      send(pid_of(room), {ref, {:ok, FakeAiModel.clean_words() ++ ["Killer Whale", "anchor"]}})

      assert state!(room).ai_words == ["killer whale"]
    end

    test "the refill asks for the room's own kind" do
      {room, creator, _player} =
        room_with_player(%{answer_kind: :phrases, word_source: :ai, prompt: "TEST ocean"})

      {:ok, _} =
        RoomServer.start_game(room.id, creator.id, %{word_choices: ["sea turtle"], ai_words: []})

      send(pid_of(room), {:refill_ai_words, room.id, 4, :fun})
      await(fn -> state!(room).ai_words != [] end)

      assert state!(room).ai_words == FakeAiModel.clean_phrases()
    end
  end

  describe "rooms of every kind" do
    setup do
      Games.sync_words()
      :ok
    end

    for answer_kind <- [:words, :mixed] do
      test "#{answer_kind}: an AI room follows its kind through the game" do
        answer_kind = unquote(answer_kind)

        {room, creator, _player} =
          room_with_player(%{answer_kind: answer_kind, word_source: :ai, prompt: "TEST ocean"})

        GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))
        assert_kind(answer_kind, drawer_choices(room))

        for _turn <- 2..6 do
          assert_kind(answer_kind, next_turn!(room).word_choices)
        end
      end
    end

    test "a room restored after a restart keeps its kind" do
      {room, creator, _player} = room_with_player(%{answer_kind: :phrases})

      kill_room!(room)
      {:ok, _pid} = RoomServer.ensure_started(room.id)

      assert state!(room).answer_kind == :phrases
      assert {:ok, %{answer_kind: :phrases}} = RoomServer.get_state(room.id)

      {:ok, started} = RoomServer.start_game(room.id, creator.id, %{})
      assert_kind(:phrases, drawer_choices(room))

      # The drawer lets the timer run out: the auto-pick is one of them.
      choices = drawer_choices(room)
      send(pid_of(room), {:word_choice_timeout, started.game_id, 1})
      assert %{phase: :drawing, current_word: word} = state!(room)
      assert word in choices
    end

    test "a failed AI call falls back to curated words of the room's kind" do
      {room, creator, _player} =
        room_with_player(%{answer_kind: :phrases, word_source: :ai, prompt: "TEST fail"})

      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      assert_kind(:phrases, drawer_choices(room))
      assert state!(room).ai_words == []

      assert Enum.any?(
               state!(room).chat_messages,
               &(&1.message == "couldn't get themed phrases, using the built-in list")
             )
    end

    test "a model call that raises still starts the game, with the built-in list" do
      {room, creator, _player} =
        room_with_player(%{answer_kind: :mixed, word_source: :ai, prompt: "TEST raise"})

      server = GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      assert server.next_action == nil
      assert state!(room).status == :playing
      assert_kind(:mixed, drawer_choices(room))

      assert Enum.any?(
               state!(room).chat_messages,
               &(&1.message == "couldn't get themed words, using the built-in list")
             )
    end
  end
end
