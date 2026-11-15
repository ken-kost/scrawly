defmodule Scrawly.Games.RoomThemesTest do
  @moduledoc """
  A room can play only some of the built-in list's themes (themes):

    * the Room's `themes` (`[]` is every theme; a room that plays its own
      theme keeps none);
    * the drawer's choices come from them, and a slot widens only when they
      run out: another difficulty within the themes first (labelled with its
      real difficulty), then any theme; never the wrong kind, never empty,
      no repeats while unused entries remain;
    * the themes go through the room process (and its restart), its views
      and deltas, the lobby settings and Home's summaries.

  The form side (topic, chips, labels, parsing) is in
  `ScrawlyWeb.RoomSettingsTest` and `ScrawlyWeb.Components.RoomSettingsFormTest`.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.{AnswerKind, RoomServer, WordList}
  alias Scrawly.Games.RoomServer.{GameFlow, View}
  alias ScrawlyWeb.Pages.GamePage
  alias ScrawlyWeb.RoomSettings

  @moduletag :capture_log

  @entries Map.new(WordList.entries(), &{&1.text, &1})
  # The most rounds a game can have, so "a whole game" is the longest one.
  @full_game Games.Game.max_total_rounds()

  setup do
    Games.sync_words()
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp entry!(text), do: Map.fetch!(@entries, text)

  defp texts(choices), do: Enum.map(choices, & &1.text)

  defp kind_of(:words), do: :word
  defp kind_of(:phrases), do: :phrase

  # The curated entries of `kind` in `themes` (`[]`: every theme).
  defp curated(kind, themes) do
    for entry <- WordList.entries(),
        AnswerKind.of(entry.text) == kind,
        themes == [] or entry.theme in themes,
        do: entry
  end

  defp pick(used, answer_kind, themes),
    do: GameFlow.pick_word_choices([], used, answer_kind, 3, themes: themes)

  # A whole game of `answer_kind` in `themes`, the drawer committing
  # `commit.(choices)` each turn. Returns every set with the words played
  # before it.
  defp play(answer_kind, themes, commit) do
    {sets, _used} =
      Enum.map_reduce(1..@full_game, [], fn _turn, used ->
        {choices, [], 0} = pick(used, answer_kind, themes)
        {{choices, used}, [commit.(choices).text | used]}
      end)

    sets
  end

  defp hardest(choices), do: List.last(choices)

  # What every themed set of a Words or Phrases room keeps to: three
  # distinct unused entries of the room's kind, labelled with their real
  # difficulty, easy to hard; as many in the themes as there are unused ones
  # (all three, until they run out); and each difficulty the themes still
  # have is offered from them.
  defp assert_themed_set(choices, used, answer_kind, themes) do
    kind = kind_of(answer_kind)
    assert length(choices) == 3, inspect(choices)
    assert Enum.uniq(texts(choices)) == texts(choices)
    assert Enum.all?(choices, &(AnswerKind.of(&1.text) == kind)), inspect(choices)
    refute Enum.any?(choices, &(&1.text in used)), inspect(choices)

    for %{text: text, difficulty: difficulty} <- choices,
        do: assert(entry!(text).difficulty == difficulty, "#{text} is not #{difficulty}")

    ranks =
      Enum.map(choices, &Enum.find_index(WordList.difficulties(), fn d -> d == &1.difficulty end))

    assert ranks == Enum.sort(ranks), inspect(choices)

    unused = Enum.reject(curated(kind, themes), &(&1.text in used))
    in_themes = Enum.filter(choices, &(entry!(&1.text).theme in themes))
    assert length(in_themes) == min(3, length(unused)), inspect({choices, length(unused)})

    for difficulty <- unused |> Enum.map(& &1.difficulty) |> Enum.uniq() do
      assert Enum.any?(in_themes, &(&1.difficulty == difficulty)),
             "no #{difficulty} choice from #{inspect(themes)}: #{inspect(choices)}"
    end
  end

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp state!(room), do: :sys.get_state(pid_of(room))

  defp room_with_player(attrs) do
    creator = create_user()
    player = create_user()
    room = start_room(creator, Map.merge(%{max_players: 4}, attrs))

    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(player)).next_action.name ==
             :room_resynced

    {room, creator, player}
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

  defp subscribe(channel),
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))

  defp drain(acc \\ []) do
    receive do
      {:broadcast_action, channel, action, params, _except} ->
        drain([{channel, action, params} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # ── The Room ──────────────────────────────────────────────────────────────

  describe "the Room's themes" do
    test "a new room plays every theme; a themed one stores its themes" do
      creator = create_user()
      assert start_room(creator).themes == []

      room = start_room(create_user(), %{themes: [:animals, :food]})
      assert reload_room!(room).themes == [:animals, :food]
    end

    test "a value outside the themes is refused, never stored" do
      creator = create_user()

      for forged <- [[:bogus], ["Elixir.Kernel"], [:animals, nil], "animals"] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Games.create_room(%{name: "TEST forged", creator_id: creator.id, themes: forged})
      end
    end

    test "a room that plays its own theme keeps none, created or changed" do
      creator = create_user()

      {:ok, ai_room} =
        Games.create_room(%{
          name: "TEST ai",
          creator_id: creator.id,
          word_source: :ai,
          prompt: "TEST ocean",
          themes: [:animals]
        })

      assert ai_room.themes == []

      room = start_room(create_user(), %{themes: [:animals]})

      {:ok, changed} =
        Games.update_room_settings(room, %{word_source: :ai, prompt: "TEST ocean"})

      assert changed.themes == []

      # Leaving word_source out leaves the themes as they are.
      room = start_room(create_user(), %{themes: [:food]})
      {:ok, renamed} = Games.update_room_settings(room, %{name: "TEST renamed"})
      assert renamed.themes == [:food]

      # The same by id (the room process's way), and the other way round:
      # back to the built-in list drops the AI theme.
      room = start_room(create_user(), %{themes: [:food]})
      {:ok, changed} = Games.update_room_settings(room.id, %{word_source: :ai, prompt: "TEST x"})
      assert changed.themes == []

      {:ok, local} = Games.update_room_settings(changed, %{word_source: :local, themes: [:food]})
      assert {local.prompt, local.themes} == {nil, [:food]}
      assert {reload_room!(room).prompt, reload_room!(room).themes} == {nil, [:food]}
    end
  end

  # ── Choices ───────────────────────────────────────────────────────────────

  describe "choices in a themed room" do
    test "animals with Words: only animal words, for a whole game" do
      for commit <- [&hd/1, &hardest/1, &Enum.random/1] do
        for {choices, used} <- play(:words, [:animals], commit) do
          assert_themed_set(choices, used, :words, [:animals])
          assert Enum.all?(choices, &(entry!(&1.text).theme == :animals)), inspect(choices)
        end
      end
    end

    test "animals with Phrases: animal phrases, widening to another difficulty when one runs out" do
      # The drawer always takes the hard one: the 7 hard animal phrases run
      # out, and the hard slot then offers a medium animal phrase, labelled
      # medium. Animals has enough phrases for a whole game, so no other
      # theme comes in.
      hard = length(Enum.filter(curated(:phrase, [:animals]), &(&1.difficulty == :hard)))
      assert hard < @full_game

      sets = play(:phrases, [:animals], &hardest/1)

      for {choices, used} <- sets do
        assert_themed_set(choices, used, :phrases, [:animals])
        assert Enum.all?(choices, &(entry!(&1.text).theme == :animals)), inspect(choices)
      end

      difficulties = Enum.map(sets, fn {choices, _} -> Enum.map(choices, & &1.difficulty) end)
      assert Enum.take(difficulties, hard) == List.duplicate([:easy, :medium, :hard], hard)
      assert Enum.at(difficulties, hard) == [:easy, :medium, :medium]
    end

    test "one theme with Phrases, every theme, a whole game: the worst case holds" do
      for theme <- WordList.themes(), commit <- [&hardest/1, &Enum.random/1] do
        for {choices, used} <- play(:phrases, [theme], commit) do
          assert_themed_set(choices, used, :phrases, [theme])
        end
      end
    end

    test "Mixed: one phrase among words, all from the themes" do
      for {choices, _used} <- play(:mixed, [:food, :sports], &Enum.random/1) do
        assert Enum.count(choices, &(AnswerKind.of(&1.text) == :phrase)) == 1
        assert Enum.all?(choices, &(entry!(&1.text).theme in [:food, :sports])), inspect(choices)
      end
    end

    test "several themes: every choice is from one of them, and both come up" do
      themes = [:transport, :fantasy]
      sets = play(:words, themes, &Enum.random/1)

      for {choices, used} <- sets, do: assert_themed_set(choices, used, :words, themes)

      seen =
        for {choices, _used} <- sets, choice <- choices, uniq: true, do: entry!(choice.text).theme

      assert Enum.sort(seen) == [:fantasy, :transport]
    end
  end

  describe "when the themes run out" do
    test "1. another difficulty within the themes, labelled truthfully" do
      used = for e <- curated(:phrase, [:animals]), e.difficulty == :hard, do: e.text

      for _ <- 1..10 do
        {choices, [], 0} = pick(used, :phrases, [:animals])
        assert Enum.map(choices, & &1.difficulty) == [:easy, :medium, :medium]
        assert Enum.all?(choices, &(entry!(&1.text).theme == :animals))
        assert_themed_set(choices, used, :phrases, [:animals])
      end
    end

    test "2. then any theme, of the slot's difficulty, never a word" do
      kept = Enum.find(curated(:phrase, [:animals]), &(&1.difficulty == :easy))
      used = for(e <- curated(:phrase, [:animals]), do: e.text) -- [kept.text]

      for _ <- 1..10 do
        {choices, [], 0} = pick(used, :phrases, [:animals])
        assert_themed_set(choices, used, :phrases, [:animals])
        assert hd(choices) == %{text: kept.text, difficulty: :easy}
        assert Enum.map(choices, & &1.difficulty) == [:easy, :medium, :hard]
        assert Enum.count(choices, &(entry!(&1.text).theme == :animals)) == 1
      end
    end

    test "3. every entry of the themes played: three unused ones of any theme" do
      used = for e <- curated(:phrase, [:places]), do: e.text

      for _ <- 1..10 do
        {choices, [], 0} = pick(used, :phrases, [:places])
        assert_themed_set(choices, used, :phrases, [:places])
        assert Enum.map(choices, & &1.difficulty) == [:easy, :medium, :hard]
        refute Enum.any?(choices, &(entry!(&1.text).theme == :places))
      end
    end

    test "4. every entry of the kind played: still three distinct ones, from the themes first" do
      used = for e <- curated(:phrase, []), do: e.text

      {choices, [], 0} = pick(used, :phrases, [:food])
      assert length(choices) == 3 and Enum.uniq(texts(choices)) == texts(choices)
      assert Enum.all?(choices, &(AnswerKind.of(&1.text) == :phrase))
      assert Enum.all?(choices, &(entry!(&1.text).theme == :food))
    end

    test "an empty words table: the built-in list of the themes" do
      Games.Word |> Ash.read!() |> Enum.each(&Ash.destroy!/1)
      seed_test_words()

      for {choices, used} <- play(:words, [:sports], &Enum.random/1) do
        assert_themed_set(choices, used, :words, [:sports])
      end
    end
  end

  # `Scrawly.Games.WordChoicesTest` and `ChoiceDifficultyTest`, unchanged,
  # check the rest of "everything".
  describe "everything" do
    test "a room without themes offers every theme" do
      themes =
        for _ <- 1..30,
            choice <- elem(pick([], :words, []), 0),
            uniq: true,
            do: entry!(choice.text).theme

      assert length(themes) > 5
    end
  end

  describe "AI rooms" do
    test "ignore themes: their choices come from every theme" do
      assert GameFlow.choice_themes(%{word_source: :ai, themes: [:animals]}) == []
      assert GameFlow.choice_themes(%{word_source: :local, themes: [:animals]}) == [:animals]
      assert GameFlow.choice_themes(%RoomServer{}) == []
    end

    test "a stored AI room with themes is read without them" do
      {room, _creator, _player} =
        room_with_player(%{word_source: :ai, prompt: "TEST fail", answer_kind: :words})

      # Bypasses the Room's own rule, as an old or hand-edited row might.
      {1, _} =
        Scrawly.Repo.update_all(
          from(r in "rooms", where: r.id == type(^room.id, Ecto.UUID)),
          set: [themes: ["animals"]]
        )

      kill_room!(room)
      {:ok, _pid} = RoomServer.ensure_started(room.id)
      assert state!(room).themes == []
      assert View.lobby_summary(state!(room)).themes == []
    end
  end

  # ── Plumbing ──────────────────────────────────────────────────────────────

  describe "through the room" do
    test "the room process, its views, deltas and Home's summary carry the themes" do
      {room, _creator, player} = room_with_player(%{themes: [:animals, :food]})
      state = state!(room)

      assert state.themes == [:animals, :food]
      assert View.public(state).themes == [:animals, :food]
      assert View.delta(state).themes == [:animals, :food]
      assert View.settings(state).themes == [:animals, :food]
      assert View.for_viewer(state, player.id).themes == [:animals, :food]

      assert Enum.find(RoomServer.list_lobby_rooms(), &(&1.room_id == room.id)).themes ==
               [:animals, :food]

      kill_room!(room)
      {:ok, _pid} = RoomServer.ensure_started(room.id)
      assert state!(room).themes == [:animals, :food]
    end

    test "a whole game in an animals Words room offers only animal words" do
      {room, creator, _player} =
        room_with_player(%{answer_kind: :words, themes: [:animals], round_multiplier: 5})

      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))
      first = state!(room)
      assert first.total_rounds == 10

      sets =
        [first.word_choices] ++
          for _turn <- 2..first.total_rounds, do: next_turn!(room).word_choices

      for choices <- sets do
        assert length(choices) == 3
        assert Enum.all?(choices, &(entry!(&1.text).theme == :animals)), inspect(choices)
        assert Enum.all?(choices, &(AnswerKind.of(&1.text) == :word))
      end

      offered = sets |> List.flatten() |> texts()
      assert length(Enum.uniq(offered)) > 10
    end

    test "the host changes them in the lobby: stored, sent, shown on Home; back to everything clears them" do
      {room, creator, _player} = room_with_player(%{answer_kind: :phrases})
      subscribe({:room, room.id})
      subscribe(:lobby)

      values = %{
        RoomSettings.form_values(reload_room!(room))
        | word_source: "themes",
          themes: ["sports", "animals", "Elixir.Kernel", "food"]
      }

      {:ok, _} =
        RoomServer.update_settings(room.id, creator.id, RoomSettings.to_attrs(values, "u"))

      assert reload_room!(room).themes == [:animals, :food, :sports]
      assert state!(room).themes == [:animals, :food, :sports]

      assert [
               {{:room, _}, :chat_appended, _},
               {{:room, _}, :room_delta, %{themes: [:animals, :food, :sports]} = delta},
               {:lobby, :lobby_room_changed, %{room: %{themes: [:animals, :food, :sports]}}}
             ] = drain()

      assert struct_free?(delta)

      # The same themes again: nothing changes, nothing is sent.
      {:ok, _} =
        RoomServer.update_settings(room.id, creator.id, RoomSettings.to_attrs(values, "u"))

      assert drain() == []

      # The next game plays them.
      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      assert Enum.all?(
               state!(room).word_choices,
               &(entry!(&1.text).theme in [:animals, :food, :sports])
             )

      {:ok, _} = RoomServer.end_game(room.id)
      send(pid_of(room), :return_to_lobby)
      assert %{status: :lobby} = room_state!(room.id)
      drain()

      # Everything, and your own theme: both clear them.
      {:ok, _} =
        RoomServer.update_settings(
          room.id,
          creator.id,
          RoomSettings.to_attrs(%{values | word_source: "local"}, "u")
        )

      assert reload_room!(room).themes == []
      assert state!(room).themes == []

      {:ok, _} =
        RoomServer.update_settings(
          room.id,
          creator.id,
          RoomSettings.to_attrs(values, "u")
        )

      assert state!(room).themes == [:animals, :food, :sports]

      {:ok, _} =
        RoomServer.update_settings(
          room.id,
          creator.id,
          RoomSettings.to_attrs(%{values | word_source: "ai", prompt: "TEST ocean"}, "u")
        )

      assert %{word_source: :ai, themes: []} = reload_room!(room)
      assert state!(room).themes == []
    end
  end
end
