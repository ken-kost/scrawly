defmodule Scrawly.Games.WordChoicesTest do
  @moduledoc """
  A room's answer kind holds for every set of choices its drawers see:
  Words rooms never offer a phrase, Phrases rooms never offer a word, and
  every Mixed set has exactly one phrase. Checked for the curated words, the
  built-in fallback, the AI's (`Scrawly.FakeAiModel` replies like a model
  that ignores the rule), refills, and a room restored after a restart.

  Every set of curated choices is one easy, one medium and one hard entry,
  in that order, each labelled with its real difficulty (also when a
  difficulty runs out); AI choices carry no difficulty.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.{FakeAiModel, Games}
  alias Scrawly.Games.{AiWords, AnswerKind, RoomServer, Word, WordList}
  alias Scrawly.Games.RoomServer.GameFlow
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  doctest GameFlow, only: [slot_difficulties: 1]

  @sets 60

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp texts(choices), do: Enum.map(choices, & &1.text)

  defp phrases_in(choices), do: Enum.count(choices, &(AnswerKind.of(&1.text) == :phrase))

  defp difficulties(choices), do: Enum.map(choices, & &1.difficulty)

  # Every curated entry's difficulty, by text.
  defp file_difficulty(text) do
    Enum.find_value(WordList.entries(), fn entry ->
      if entry.text == text, do: entry.difficulty
    end)
  end

  # Each choice carries its entry's real difficulty, and the set reads easy
  # to hard.
  defp assert_labelled(choices) do
    for %{text: text, difficulty: difficulty} <- choices,
        do: assert(file_difficulty(text) == difficulty, "#{text} is not #{difficulty}")

    ranks =
      Enum.map(choices, &Enum.find_index(WordList.difficulties(), fn d -> d == &1.difficulty end))

    assert ranks == Enum.sort(ranks), "#{inspect(choices)}"
  end

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
        assert Enum.uniq(texts(choices)) == texts(choices)
        assert Enum.all?(pool, &AnswerKind.allows?(answer_kind, &1))
        {choices, {pool, [hd(choices).text | used]}}
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

    {:ok, _} =
      RoomServer.choose_word(room.id, state.current_drawer_id, hd(state.word_choices).text)

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
        assert sets |> List.flatten() |> texts() |> Enum.uniq() |> length() > 100
      end

      test "#{answer_kind}: every set is one easy, one medium and one hard, in that order" do
        for choices <- play_turns(unquote(answer_kind), []) do
          assert difficulties(choices) == [:easy, :medium, :hard]
          assert_labelled(choices)
        end
      end
    end

    test "phrases of two, three and four words are all offered" do
      lengths =
        for _ <- 1..@sets,
            %{text: text} <- elem(GameFlow.pick_word_choices([], [], :phrases, 3), 0) do
          length(String.split(text))
        end

      assert Enum.sort(Enum.uniq(lengths)) == [2, 3, 4]
    end

    test "mixed puts the phrase at every position, with that slot's difficulty" do
      phrases =
        for _ <- 1..@sets do
          {choices, _, _} = GameFlow.pick_word_choices([], [], :mixed, 3)
          index = Enum.find_index(choices, &(AnswerKind.of(&1.text) == :phrase))
          {index, Enum.at(choices, index).difficulty}
        end

      assert phrases |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == [0, 1, 2]
      assert Enum.uniq(phrases) |> Enum.sort() == [{0, :easy}, {1, :medium}, {2, :hard}]
    end
  end

  describe "when a difficulty runs out" do
    setup do
      Games.sync_words()
      :ok
    end

    test "a slot takes another difficulty of the same kind, labelled truthfully" do
      # Every medium word has been played: the medium slot takes an easy one.
      used = Word.builtin_words(:word, :medium)

      for _ <- 1..10 do
        {choices, [], 0} = GameFlow.pick_word_choices([], used, :words, 3)
        assert_kind(:words, choices)
        assert difficulties(choices) == [:easy, :easy, :hard]
        assert_labelled(choices)
        assert Enum.uniq(texts(choices)) == texts(choices)
        refute Enum.any?(choices, &(&1.text in used))
      end

      # No hard phrase left: a hard phrase slot takes a medium phrase, never
      # a word.
      used = Word.builtin_words(:phrase, :hard)

      for _ <- 1..10 do
        {choices, [], 0} = GameFlow.pick_word_choices([], used, :phrases, 3)
        assert_kind(:phrases, choices)
        assert difficulties(choices) == [:easy, :medium, :medium]
        assert_labelled(choices)
        refute Enum.any?(choices, &(&1.text in used))
      end

      for _ <- 1..@sets do
        {choices, [], 0} = GameFlow.pick_word_choices([], used, :mixed, 3)
        assert_kind(:mixed, choices)
        assert_labelled(choices)
        assert [%{difficulty: phrase_difficulty}] = Enum.filter(choices, &(&1.text =~ " "))
        assert phrase_difficulty in [:easy, :medium]
      end
    end

    test "with every entry of a kind played, the set is still three distinct ones of that kind" do
      for answer_kind <- [:words, :phrases] do
        kind = if answer_kind == :words, do: :word, else: :phrase
        used = Word.builtin_words(kind)

        {choices, [], 0} = GameFlow.pick_word_choices([], used, answer_kind, 3)
        assert_kind(answer_kind, choices)
        assert difficulties(choices) == [:easy, :medium, :hard]
        assert_labelled(choices)
        assert Enum.uniq(texts(choices)) == texts(choices)
      end
    end

    test "a small words table is topped up from the built-in list of the slot's difficulty" do
      Games.Word |> Ash.read!() |> Enum.each(&Ash.destroy!/1)
      seed_test_words()
      used = for d <- [:easy, :medium, :hard], i <- 1..4, do: "test#{d}#{i}"

      {choices, [], 0} = GameFlow.pick_word_choices([], used, :words, 3)
      assert difficulties(choices) == [:easy, :medium, :hard]
      assert_labelled(choices)
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
        assert hd(choices) == %{text: "test'cat", difficulty: nil}

        assert choices
               |> texts()
               |> Enum.map(&Scrawly.Games.Guess.key/1)
               |> Enum.uniq()
               |> length() ==
                 3
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
          ai = FakeAiModel.clean_words() ++ FakeAiModel.clean_phrases()

          # The AI's entries are offered first, without a difficulty, then
          # the curated words with theirs.
          assert Enum.any?(offered, &(&1.difficulty == nil))

          for choice <- offered do
            if choice.difficulty == nil,
              do: assert(choice.text in ai),
              else: assert(choice.difficulty == file_difficulty(choice.text))
          end
        end
      end
    end

    test "in mixed, the AI's phrase fills the phrase slot and its words the others" do
      pool = AiWords.filter(FakeAiModel.reply(), :mixed)

      {choices, remaining, 3} = GameFlow.pick_word_choices(pool, [], :mixed, 3)
      assert_kind(:mixed, choices)
      assert Enum.all?(choices, &(&1.text in pool))
      assert difficulties(choices) == [nil, nil, nil]
      assert length(remaining) == length(pool) - 3

      # Only phrases left: the words come from the curated list, with the
      # difficulties of their slots.
      phrases = FakeAiModel.clean_phrases()
      {choices, remaining, 1} = GameFlow.pick_word_choices(phrases, [], :mixed, 3)
      assert_kind(:mixed, choices)
      assert [%{text: phrase, difficulty: nil}] = Enum.filter(choices, &(&1.text in phrases))
      assert remaining == phrases -- [phrase]
      local = Enum.reject(choices, &(&1.text in phrases))
      assert length(local) == 2
      assert_labelled(local)
    end

    test "words already played are not offered again, whatever their spelling" do
      {choices, remaining, 1} =
        GameFlow.pick_word_choices(["test lagoon", "beach ball"], ["Test-Lagoon!"], :phrases, 3)

      refute "test lagoon" in texts(choices)
      assert %{text: "beach ball", difficulty: nil} in choices
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
      assert Enum.all?(drawer_choices(room), &(&1.text in FakeAiModel.clean_phrases()))
      # AI answers are shown without a difficulty.
      assert difficulties(drawer_choices(room)) == [nil, nil, nil]
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
        RoomServer.start_game(room.id, creator.id, %{
          word_choices: choices(["sea turtle"]),
          ai_words: []
        })

      ref = make_ref()
      :sys.replace_state(pid_of(room), &%{&1 | ai_refill: {ref, started.game_id}})
      send(pid_of(room), {ref, {:ok, FakeAiModel.clean_words() ++ ["Killer Whale", "anchor"]}})

      assert state!(room).ai_words == ["killer whale"]
    end

    test "the refill asks for the room's own kind" do
      {room, creator, _player} =
        room_with_player(%{answer_kind: :phrases, word_source: :ai, prompt: "TEST ocean"})

      {:ok, _} =
        RoomServer.start_game(room.id, creator.id, %{
          word_choices: choices(["sea turtle"]),
          ai_words: []
        })

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
      assert difficulties(drawer_choices(room)) == [:easy, :medium, :hard]

      # The drawer lets the timer run out: the auto-pick is a random one of
      # them (Enum.random/1 on the room's own list), with its difficulty.
      # Seeding the room process pins which one.
      choices = drawer_choices(room)
      seed = {:exsss, {28, 2, 8}}

      :sys.replace_state(pid_of(room), fn state ->
        :rand.seed(elem(seed, 0), elem(seed, 1))
        state
      end)

      :rand.seed(elem(seed, 0), elem(seed, 1))
      expected = Enum.random(choices)

      send(pid_of(room), {:word_choice_timeout, started.game_id, 1})
      assert %{phase: :drawing} = state = state!(room)

      assert {state.current_word, state.current_difficulty} ==
               {expected.text, expected.difficulty}

      assert {:ok, %{word_difficulty: difficulty}} = RoomServer.get_view(room.id, nil)
      assert difficulty == expected.difficulty
    end

    test "a failed AI call falls back to curated words of the room's kind" do
      {room, creator, _player} =
        room_with_player(%{answer_kind: :phrases, word_source: :ai, prompt: "TEST fail"})

      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      assert_kind(:phrases, drawer_choices(room))
      assert difficulties(drawer_choices(room)) == [:easy, :medium, :hard]
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
