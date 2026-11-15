defmodule Scrawly.Games.WordStatsTest do
  @moduledoc """
  Per-word play stats (`Scrawly.Games.WordStats`, table `word_stats`):

    * each counter moves at its moment: `offered` when a set of choices is
      shown, `picked` when the drawer or the choice timer picks, `rounds`,
      `guessers`, `correct` and the first-guess time when a round is played
      to its end (time up or everyone guessed);
    * only curated entries count: AI rooms, AI answers (even one whose text
      is on the list), rounds the drawer left, and players who weren't
      there for the whole round are left out;
    * a failing write changes nothing in the round;
    * the rows are keyed by text: the word sync keeps them;
    * the report's three lists and their thresholds.
  """
  use Scrawly.DataCase, async: false

  import ExUnit.CaptureLog
  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.{RoomServer, WordList, WordStat, WordStats}
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @header "text,difficulty,theme,list,offered,picked,pick_rate,rounds,guessers,correct," <>
            "guess_rate,first_guess_rounds,first_guess_avg_s"

  setup do
    Games.sync_words()
    previous = Application.get_env(:scrawly, WordStats)
    Application.put_env(:scrawly, WordStats, record?: true)
    on_exit(fn -> Application.put_env(:scrawly, WordStats, previous) end)
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Waits until every stats write the rooms have started is done (they run
  # under Scrawly.TaskSupervisor). Call it once the room has handled the
  # event (a call to the room, or :sys.get_state after a message).
  defp await_writes do
    for pid <- Task.Supervisor.children(Scrawly.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    :ok
  end

  # Every row's counters, by text.
  defp stats do
    await_writes()
    Map.new(Games.list_word_stats!(), &{&1.text, Map.take(&1, WordStat.counters())})
  end

  defp zero, do: Map.new(WordStat.counters(), &{&1, 0})

  # `expected` with `counts` added to `text`'s row.
  defp bump(expected, text, counts) do
    Map.update(expected, text, Map.merge(zero(), counts), fn row ->
      Map.merge(row, counts, fn _counter, a, b -> a + b end)
    end)
  end

  defp entries(difficulty, kind \\ :word) do
    for entry <- WordList.entries(),
        entry.difficulty == difficulty,
        Scrawly.Games.AnswerKind.of(entry.text) == kind,
        do: entry
  end

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp state!(room), do: :sys.get_state(pid_of(room))

  defp room_with(count, attrs \\ %{}) do
    [creator | others] = users = for _ <- 1..count, do: create_user()
    room = start_room(creator, Map.merge(%{max_players: 6}, attrs))

    for user <- others do
      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
               :room_resynced
    end

    {room, users}
  end

  defp start!(room, creator) do
    GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))
    assert %{phase: :choosing} = state = state!(room)
    state
  end

  defp choose!(room, text) do
    state = state!(room)

    assert {:ok, %{phase: :drawing}} =
             RoomServer.choose_word(room.id, state.current_drawer_id, text)

    text
  end

  defp auto_pick!(room) do
    state = state!(room)
    send(pid_of(room), {:word_choice_timeout, state.game_id, state.current_round})
    assert %{phase: :drawing, current_word: word} = state!(room)
    word
  end

  defp guess!(room, user, word),
    do: assert({:ok, {:correct, _points}} = RoomServer.submit_message(room.id, user.id, word))

  defp advance!(room) do
    send(pid_of(room), :auto_advance_round)
    state!(room)
  end

  # Moves the drawing's start `ms` into the past: the next guess comes `ms`
  # after it began.
  defp drawing_began_ago!(room, ms) do
    :sys.replace_state(pid_of(room), fn state ->
      round_ms = round(state.round_duration * 1000)
      %{state | round_deadline: System.monotonic_time(:millisecond) + round_ms - ms}
    end)
  end

  # A game in `room` whose first round offers `choices` (a `GameFlow.choice/0`
  # list), started by `creator`.
  defp start_with!(room, creator, choices) do
    assert {:ok, _} = RoomServer.start_game(room.id, creator.id, %{word_choices: choices})
    state!(room)
  end

  defp refuse_stats_writes! do
    Scrawly.Repo.query!("""
    CREATE FUNCTION test_refuse_word_stats() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'TEST stats refused'; END $$ LANGUAGE plpgsql
    """)

    Scrawly.Repo.query!("""
    CREATE TRIGGER test_refuse_word_stats BEFORE INSERT OR UPDATE ON word_stats
    FOR EACH ROW EXECUTE FUNCTION test_refuse_word_stats()
    """)
  end

  # ── The table ─────────────────────────────────────────────────────────────

  describe "the word_stats table" do
    test "a first sighting inserts the row, later records add to it" do
      Games.record_word_stats!(%{text: "cat", offered: 1})
      Games.record_word_stats!(%{text: "cat", offered: 1, picked: 1})

      Games.record_word_stats!(%{
        text: "cat",
        rounds: 1,
        guessers: 3,
        correct: 2,
        first_guess_ms_sum: 4_200,
        first_guess_rounds: 1
      })

      assert stats() == %{
               "cat" => %{
                 offered: 2,
                 picked: 1,
                 rounds: 1,
                 guessers: 3,
                 correct: 2,
                 first_guess_ms_sum: 4_200,
                 first_guess_rounds: 1
               }
             }
    end

    test "a list of rows is one upsert: new rows inserted, existing ones added to" do
      Games.record_word_stats!(%{text: "cat", offered: 3})

      result =
        Games.record_word_stats([%{text: "cat", offered: 1}, %{text: "dog", offered: 1}],
          bulk_options: [return_errors?: true, stop_on_error?: true, return_records?: false]
        )

      assert result.status == :success
      assert %{"cat" => %{offered: 4}, "dog" => %{offered: 1}} = stats()
    end

    test "the word sync keeps the stats, also of an entry whose words row it re-inserts" do
      Games.record_word_stats!(%{text: "cat", offered: 4, picked: 1})
      Games.record_word_stats!(%{text: "TEST gone from the file", offered: 2})
      before = stats()

      # A rename or a deleted row: the sync deletes and inserts words rows,
      # never stats.
      Games.get_all_words!() |> Enum.find(&(&1.text == "cat")) |> Ash.destroy!()
      assert %{inserted: 1} = Games.sync_words()
      assert %{inserted: 0, updated: 0, deleted: 0} = Games.sync_words()

      assert stats() == before
    end
  end

  # ── Through a room ────────────────────────────────────────────────────────

  describe "a game with the built-in words" do
    test "every offered, picked and played entry has matching numbers" do
      {room, [creator, first, second]} = room_with(3)
      state = start!(room, creator)
      assert state.total_rounds == 3

      # Round 1: the creator picks the medium one; one of two guesses it.
      expected = Enum.reduce(state.word_choices, %{}, &bump(&2, &1.text, %{offered: 1}))
      word = choose!(room, Enum.at(state.word_choices, 1).text)
      guess!(room, first, word)
      assert expire_round!(room).phase == :round_end

      expected =
        bump(expected, word, %{
          picked: 1,
          rounds: 1,
          guessers: 2,
          correct: 1,
          first_guess_rounds: 1
        })

      # Round 2: the timer picks; everyone guesses.
      state = advance!(room)
      assert state.current_drawer_id == first.id
      expected = Enum.reduce(state.word_choices, expected, &bump(&2, &1.text, %{offered: 1}))
      word = auto_pick!(room)
      guess!(room, creator, word)
      guess!(room, second, word)
      assert state!(room).phase == :round_end

      expected =
        bump(expected, word, %{
          picked: 1,
          rounds: 1,
          guessers: 2,
          correct: 2,
          first_guess_rounds: 1
        })

      # Round 3: nobody guesses.
      state = advance!(room)
      expected = Enum.reduce(state.word_choices, expected, &bump(&2, &1.text, %{offered: 1}))
      word = choose!(room, hd(state.word_choices).text)
      assert expire_round!(room).phase == :round_end
      expected = bump(expected, word, %{picked: 1, rounds: 1, guessers: 2})

      assert advance!(room).status == :post_game

      stats = stats()

      for {_text, row} <- stats do
        # Guesses came right after each drawing began.
        assert row.first_guess_ms_sum in 0..(row.first_guess_rounds * 5_000)
      end

      assert Map.new(stats, fn {text, row} -> {text, %{row | first_guess_ms_sum: 0}} end) ==
               expected

      assert Enum.all?(Map.keys(stats), &WordList.entry/1)
    end

    test "the first-guess time runs from the start of the drawing to the earliest guess" do
      {room, [creator, first, second]} = room_with(3)
      [entry | _] = entries(:easy)
      start_with!(room, creator, [%{text: entry.text, difficulty: :easy}])
      choose!(room, entry.text)

      drawing_began_ago!(room, 12_000)
      guess!(room, second, entry.text)
      drawing_began_ago!(room, 20_000)
      guess!(room, first, entry.text)

      assert %{rounds: 1, guessers: 2, correct: 2, first_guess_ms_sum: ms, first_guess_rounds: 1} =
               stats()[entry.text]

      # (Up to 2 s of slack for a slow machine: the second guess came at 20 s.)
      assert ms in 12_000..14_000
    end

    test "a player who leaves during the round counts in neither number, nor does their guess" do
      {room, [creator, leaver, guesser, _silent]} = room_with(4)
      [entry | _] = entries(:medium)
      start_with!(room, creator, [%{text: entry.text, difficulty: :medium}])
      choose!(room, entry.text)

      drawing_began_ago!(room, 5_000)
      guess!(room, leaver, entry.text)
      drawing_began_ago!(room, 15_000)
      guess!(room, guesser, entry.text)
      assert {:ok, _} = RoomServer.leave(room.id, leaver.id)
      assert expire_round!(room).phase == :round_end

      assert %{
               offered: 1,
               picked: 1,
               rounds: 1,
               guessers: 2,
               correct: 1,
               first_guess_ms_sum: ms,
               first_guess_rounds: 1
             } = stats()[entry.text]

      assert ms in 15_000..17_000
    end

    test "a player who wasn't there when the turn began counts in neither number" do
      {room, [creator, guesser]} = room_with(2)
      [entry | _] = entries(:hard)
      start_with!(room, creator, [%{text: entry.text, difficulty: :hard}])
      choose!(room, entry.text)

      # Nobody can join a game in progress; were it possible, the latecomer
      # (not in round_start_scores) would stay out of the numbers.
      late = create_user()

      :sys.replace_state(pid_of(room), fn state ->
        latecomer = %{
          id: late.id,
          username: late.username,
          score: 0,
          avatar_id: "a-mushroom",
          avatar_color: "3"
        }

        %{state | players: state.players ++ [latecomer]}
      end)

      guess!(room, late, entry.text)
      refute guesser.id in state!(room).correct_guessers
      assert expire_round!(room).phase == :round_end

      assert %{rounds: 1, guessers: 1, correct: 0, first_guess_rounds: 0, first_guess_ms_sum: 0} =
               stats()[entry.text]
    end

    test "a turn the drawer leaves is not a round played: offered and picked stay, nothing more" do
      {room, [creator, drawing_leaver, choosing_leaver, _last]} = room_with(4)
      state = start!(room, creator)
      choose!(room, hd(state.word_choices).text)
      expire_round!(room)

      # Round 2: the drawer leaves while drawing, after a guess.
      state = advance!(room)
      assert state.current_drawer_id == drawing_leaver.id
      word = choose!(room, hd(state.word_choices).text)
      guess!(room, creator, word)
      assert {:ok, _} = RoomServer.leave(room.id, drawing_leaver.id)
      assert state!(room).phase == :round_end

      # Round 3: the drawer leaves while choosing.
      state = advance!(room)
      assert state.current_drawer_id == choosing_leaver.id
      offered = Enum.map(state.word_choices, & &1.text)
      assert {:ok, _} = RoomServer.leave(room.id, choosing_leaver.id)

      stats = stats()

      assert %{offered: offered_count, picked: 1, rounds: 0, guessers: 0, correct: 0} =
               stats[word]

      assert offered_count >= 1

      for text <- offered do
        assert %{picked: 0, rounds: 0} = stats[text]
        assert stats[text].offered >= 1
      end
    end
  end

  describe "answers that aren't from the list" do
    test "an AI room's game leaves word_stats unchanged" do
      {room, [creator, guesser]} =
        room_with(2, %{word_source: :ai, prompt: "TEST ocean", round_multiplier: 2})

      state = start!(room, creator)
      assert Enum.all?(state.word_choices, &is_nil(&1.difficulty))
      # The fake model answers words that are on the list too ("octopus").
      assert Enum.any?(Scrawly.FakeAiModel.clean_words(), &WordList.entry/1)

      for turn <- 1..state.total_rounds do
        state = if turn == 1, do: state, else: advance!(room)
        word = choose!(room, hd(state.word_choices).text)
        guess!(room, if(state.current_drawer_id == creator.id, do: guesser, else: creator), word)
      end

      assert advance!(room).status == :post_game
      assert stats() == %{}
    end

    test "an AI room records nothing even when it falls back to the built-in list" do
      {room, [creator, guesser]} = room_with(2, %{word_source: :ai, prompt: "TEST fail"})
      state = start!(room, creator)
      assert Enum.all?(state.word_choices, & &1.difficulty)

      word = choose!(room, hd(state.word_choices).text)
      guess!(room, guesser, word)
      assert stats() == %{}
    end

    test "an AI answer whose text is on the list never counts; the curated choices beside it do" do
      {room, [creator, guesser]} = room_with(2)
      [easy | _] = entries(:easy)
      [hard | _] = entries(:hard)
      assert WordList.entry("octopus")

      choices = [
        %{text: easy.text, difficulty: :easy},
        %{text: "octopus", difficulty: nil},
        %{text: hard.text, difficulty: :hard}
      ]

      start_with!(room, creator, choices)
      choose!(room, "octopus")
      guess!(room, guesser, "octopus")

      assert stats() == %{
               easy.text => Map.merge(zero(), %{offered: 1}),
               hard.text => Map.merge(zero(), %{offered: 1})
             }
    end

    test "a choice whose text isn't an entry of the file gets no row" do
      {room, [creator, guesser]} = room_with(2)
      start_with!(room, creator, [%{text: "TEST not a word", difficulty: :easy}])
      choose!(room, "TEST not a word")
      guess!(room, guesser, "TEST not a word")
      assert stats() == %{}
    end
  end

  describe "a failing write" do
    test "changes nothing in the round, and is logged without the words" do
      # Long texts, so the log can't hold them by chance.
      [easy, other_easy | _] = Enum.filter(entries(:easy), &(String.length(&1.text) >= 7))
      [hard | _] = Enum.filter(entries(:hard), &(String.length(&1.text) >= 7))

      play = fn ->
        {room, [creator, guesser, other]} = room_with(3)

        start_with!(room, creator, [
          %{text: easy.text, difficulty: :easy},
          %{text: other_easy.text, difficulty: :easy},
          %{text: hard.text, difficulty: :hard}
        ])

        choose!(room, hard.text)
        guess!(room, guesser, hard.text)
        guess!(room, other, hard.text)
        ended = state!(room)
        next = advance!(room)
        await_writes()

        names = %{creator.id => "creator", guesser.id => "guesser", other.id => "other"}

        # Usernames differ between the runs ("TEST12" may even begin
        # "TEST123"): the longest is replaced first.
        roles =
          [{creator, "creator"}, {guesser, "guesser"}, {other, "other"}]
          |> Enum.sort_by(fn {user, _role} -> -String.length(user.username) end)

        %{
          phase: ended.phase,
          scores: Map.new(ended.players, &{names[&1.id], &1.score}),
          guessed: Enum.map(ended.correct_guessers, &names[&1]),
          chat:
            Enum.map(ended.chat_messages, fn line ->
              Enum.reduce(roles, line.message, fn {user, role}, text ->
                String.replace(text, user.username, role)
              end)
            end),
          results: Enum.map(ended.round_results, &Map.take(&1, [:round, :word, :difficulty])),
          next: {next.phase, next.current_round, names[next.current_drawer_id]}
        }
      end

      recorded = play.()
      before = stats()
      assert before[hard.text].rounds == 1

      refuse_stats_writes!()
      log = capture_log(fn -> assert play.() == recorded end)

      assert stats() == before

      for moment <- ["offered", "picked", "round"],
          do: assert(log =~ "word stats not saved (#{moment}): Ash.Error.")

      assert log =~ "Postgrex.Error raise_exception"
      for entry <- [easy, other_easy, hard], do: refute(log =~ entry.text)
    end
  end

  # ── The report ────────────────────────────────────────────────────────────

  describe "report/1" do
    test "an empty table: the header alone" do
      assert WordStats.report() == @header
    end

    test "too hard, too easy and rarely picked, at their thresholds" do
      [e1, e2, e3, e4 | _] = entries(:easy)
      [h1, h2, h3 | _] = entries(:hard)
      [m1, m2, m3, m4 | _] = entries(:medium)

      rows = [
        # easy: 20 rounds and under 40% -> too hard; 19 rounds, or 40%, no.
        {e1,
         %{
           rounds: 20,
           guessers: 100,
           correct: 39,
           first_guess_ms_sum: 90_000,
           first_guess_rounds: 18
         }},
        {e2, %{rounds: 19, guessers: 100, correct: 10}},
        {e3, %{rounds: 20, guessers: 100, correct: 40}},
        {e4, %{rounds: 30, guessers: 60, correct: 6}},
        # hard: over 60% -> too easy; 60% exactly, no.
        {h1, %{rounds: 20, guessers: 100, correct: 61}},
        {h2, %{rounds: 20, guessers: 100, correct: 60}},
        {h3, %{rounds: 25, guessers: 50, correct: 45}},
        # medium: never too hard or too easy.
        {m1, %{rounds: 50, guessers: 100, correct: 1}},
        # picked under 10% of at least 30 offers -> rarely picked.
        {m2, %{offered: 30, picked: 2}},
        {m3, %{offered: 30, picked: 3}},
        {m4, %{offered: 29, picked: 0}}
      ]

      for {entry, counts} <- rows,
          do: Games.record_word_stats!(Map.put(counts, :text, entry.text))

      # Stats of a text the file no longer has are left out.
      Games.record_word_stats!(%{text: "TEST gone", rounds: 99, guessers: 99, offered: 99})

      line = fn entry, rest -> "#{entry.text},#{entry.difficulty},#{entry.theme},#{rest}" end

      assert String.split(WordStats.report(), "\n") == [
               @header,
               line.(e4, "too_hard,0,0,,30,60,6,0.100,0,"),
               line.(e1, "too_hard,0,0,,20,100,39,0.390,18,5.0"),
               line.(h3, "too_easy,0,0,,25,50,45,0.900,0,"),
               line.(h1, "too_easy,0,0,,20,100,61,0.610,0,"),
               line.(m2, "rarely_picked,30,2,0.067,0,0,0,,0,")
             ]
    end

    test "options move the thresholds" do
      [easy | _] = entries(:easy)
      [medium | _] = entries(:medium)
      Games.record_word_stats!(%{text: easy.text, rounds: 5, guessers: 10, correct: 5})
      Games.record_word_stats!(%{text: medium.text, offered: 10, picked: 2})

      assert WordStats.report() == @header

      assert [@header, too_hard, rarely] =
               String.split(
                 WordStats.report(
                   min_rounds: 5,
                   easy_below: 0.55,
                   min_offered: 10,
                   picked_below: 0.25
                 ),
                 "\n"
               )

      assert too_hard =~ ~r/^#{easy.text},easy,.*,too_hard,/
      assert rarely =~ ~r/^#{medium.text},medium,.*,rarely_picked,10,2,0.200,/
      assert_raise ArgumentError, fn -> WordStats.report(min_round: 5) end
    end

    test "an entry can be in two lists; the connection stays writable after it" do
      [easy | _] = entries(:easy)

      Games.record_word_stats!(%{
        text: easy.text,
        offered: 40,
        picked: 1,
        rounds: 20,
        guessers: 40,
        correct: 4
      })

      assert [@header, too_hard, rarely] = String.split(WordStats.report(), "\n")
      assert String.starts_with?(too_hard, "#{easy.text},easy,#{easy.theme},too_hard,")
      assert String.starts_with?(rarely, "#{easy.text},easy,#{easy.theme},rarely_picked,")

      # The report's read-only transaction is rolled back.
      Games.record_word_stats!(%{text: easy.text, offered: 1})
      assert stats()[easy.text].offered == 41
    end
  end

  test "WordList.entry/1 finds an entry by its exact text" do
    assert %{text: "cat", difficulty: :easy} = WordList.entry("cat")
    assert WordList.entry("Cat") == nil
    assert WordList.entry("TEST not a word") == nil
    assert WordList.entry(nil) == nil
  end
end
