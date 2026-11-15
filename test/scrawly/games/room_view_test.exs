defmodule Scrawly.Games.RoomViewTest do
  @moduledoc """
  `RoomServer.View` decides what each viewer may see. Only the drawer's view
  ever carries the word or the word choices.
  """
  use ExUnit.Case, async: true

  alias Scrawly.Games.{RoomServer, WordHints}
  alias Scrawly.Games.RoomServer.{GameFlow, View}

  @word "zzyzx"
  @choices ["zzyzx", "quokka", "fjord"]
  @drawer "drawer-id"
  @p1 "p1-id"
  @watcher "watcher-id"
  @secret_keys [:current_word, :word_choices, :choice_deadline]

  # Every key GamePage reads from a :room_resynced snapshot with dot access, plus
  # the word fields it reads with Map.get.
  @viewer_keys [
    :is_drawer,
    :drawer_name,
    :current_word,
    :word_choices,
    :word_display,
    :word_length,
    :revealed_word,
    :round_remaining_ms,
    :choice_remaining_ms,
    :round_duration,
    :choice_duration,
    :status,
    :game_id,
    :last_game_id,
    :players,
    :max_players,
    :seq,
    :correct_guessers,
    :chat_messages,
    :watchers,
    :past_games,
    :current_round,
    :total_rounds,
    :current_drawer_id,
    :phase,
    :drawing_strokes,
    :guess_points,
    :round_summary
  ]

  # What a :room_delta and View.public/1 must carry for client countdowns.
  @time_keys [:round_remaining_ms, :choice_remaining_ms, :round_duration, :choice_duration]

  defp room(attrs) do
    struct!(
      %RoomServer{
        room_id: "TEST-room-#{System.unique_integer([:positive])}",
        name: "TEST",
        code: "ABCD",
        status: :playing,
        creator_id: @drawer,
        max_players: 4,
        game_id: "TEST-game",
        phase: :drawing,
        current_round: 1,
        total_rounds: 3,
        current_drawer_id: @drawer,
        current_word: @word,
        round_active: true,
        round_deadline: System.monotonic_time(:millisecond) + 80_000,
        hint_stage: 0,
        round_duration: 80,
        players: [
          %{id: @drawer, username: "Drawer", score: 0},
          %{id: @p1, username: "P1", score: 0}
        ],
        watchers: [%{id: @watcher, username: "Watcher"}],
        drawing_strokes: [%{path: "M0 0 L1 1", color: "#000000", width: 2}],
        round_results: [%{round: 0, word: "TESTpastword", drawing_strokes: []}]
      },
      attrs
    )
  end

  defp choosing(attrs \\ []) do
    room(
      [
        phase: :choosing,
        current_word: nil,
        round_active: false,
        round_deadline: nil,
        word_choices: @choices,
        choice_deadline: System.monotonic_time(:millisecond) + 10_000
      ] ++ attrs
    )
  end

  defp lobby do
    room(
      status: :lobby,
      game_id: nil,
      phase: :idle,
      current_round: 0,
      current_drawer_id: nil,
      current_word: nil,
      round_active: false,
      round_deadline: nil
    )
  end

  defp round_end(attrs \\ []),
    do: room([phase: :round_end, round_deadline: nil, round_active: false] ++ attrs)

  defp dump(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp refute_leaks(map, words) do
    for word <- List.wrap(words), do: refute(dump(map) =~ word)
    for key <- @secret_keys, do: refute(Map.has_key?(map, key))
  end

  describe "public/1 and delta/1" do
    test "never carry the word while drawing, whatever the hint stage" do
      for hint_stage <- [0, 1, 2] do
        state = room(hint_stage: hint_stage)
        refute_leaks(View.public(state), @word)
        refute_leaks(View.delta(state), @word)
      end
    end

    test "carry no candidate word while choosing" do
      state = choosing()
      refute_leaks(View.public(state), @choices)
      refute_leaks(View.delta(state), @choices)
    end

    test "drop round_results, keep the strokes init reads" do
      public = View.public(room([]))
      refute Map.has_key?(public, :round_results)
      refute dump(public) =~ "TESTpastword"
      assert public.drawing_strokes == room([]).drawing_strokes
    end

    test "keep the keys other pages and commands read" do
      public = View.public(lobby())

      for key <-
            [:name, :code, :players, :max_players, :status, :answer_kind, :word_source] ++
              [:prompt, :ai_tone, :round_multiplier, :round_duration, :chat_messages] do
        assert Map.has_key?(public, key)
      end
    end
  end

  describe "post_game_remaining_ms" do
    test "is the ms left before a :post_game room returns to the lobby" do
      now = System.monotonic_time(:millisecond)
      post_game = room(status: :post_game, phase: :idle, post_game_deadline: now + 12_000)

      remaining = View.public(post_game).post_game_remaining_ms
      assert remaining > 11_000 and remaining <= 12_000
      # Computed a moment later, so it may be a few ms lower, never higher.
      viewer_remaining = View.for_viewer(post_game, @p1).post_game_remaining_ms
      assert viewer_remaining <= remaining and viewer_remaining > remaining - 1_000

      overdue = %{post_game | post_game_deadline: now - 500}
      assert View.public(overdue).post_game_remaining_ms == 0
    end

    test "is nil outside :post_game and never sends the deadline itself" do
      deadline = System.monotonic_time(:millisecond) + 12_000

      for state <- [lobby(), room([]), room(status: :post_game, post_game_deadline: nil)] do
        assert View.public(state).post_game_remaining_ms == nil
      end

      post_game = room(status: :post_game, post_game_deadline: deadline)
      refute Map.has_key?(View.public(post_game), :post_game_deadline)
      refute Map.has_key?(View.delta(post_game), :post_game_deadline)
      refute dump(View.public(post_game)) =~ Integer.to_string(deadline)
    end
  end

  describe "for_viewer/2" do
    test "gives guessers, watchers and visitors no word and no choices" do
      for state <- [room([]), choosing(), round_end()],
          viewer <- [@p1, @watcher, nil] do
        view = View.for_viewer(state, viewer)

        assert view.is_drawer == false
        assert view.current_word == nil
        assert view.word_choices == []
        refute dump(Map.drop(view, [:revealed_word])) =~ @word
        refute dump(view) =~ "quokka"
      end
    end

    test "a nil viewer is not the drawer when there is no drawer" do
      view = View.for_viewer(lobby(), nil)
      assert view.is_drawer == false
      assert view.current_word == nil
      assert view.drawer_name == "Unknown"
    end

    test "gives the drawer the word while drawing and the choices while choosing" do
      drawing = View.for_viewer(room([]), @drawer)
      assert drawing.is_drawer == true
      assert drawing.current_word == @word
      assert drawing.drawer_name == "Drawer"

      choosing = View.for_viewer(choosing(), @drawer)
      assert choosing.is_drawer == true
      assert choosing.word_choices == @choices
      assert choosing.current_word == nil
    end

    test "always has every key the game page reads" do
      for state <- [lobby(), choosing(), room([]), round_end()],
          viewer <- [@drawer, @p1, nil],
          key <- @viewer_keys do
        assert Map.has_key?(View.for_viewer(state, viewer), key),
               "#{inspect(key)} missing for #{inspect(viewer)} in #{state.phase}"
      end
    end
  end

  describe "word fields" do
    test "word_display is the mask of the room's hint stage" do
      word = "watermelon"
      display = fn stage -> View.public(room(current_word: word, hint_stage: stage)) end

      hidden = display.(0).word_display
      assert hidden == "_ _ _ _ _ _ _ _ _ _"

      # The same letters generate_hint/4 shows between 37.5% and 68.75%
      # elapsed, and after 68.75%.
      stage1 = display.(1).word_display
      assert stage1 != hidden
      assert stage1 == WordHints.generate_hint(word, 50, 80)

      stage2 = display.(2).word_display
      assert stage2 != stage1
      assert stage2 == WordHints.generate_hint(word, 25, 80)
      assert revealed_count(stage1) < revealed_count(stage2)
      refute stage2 =~ word

      assert View.delta(room(current_word: word, hint_stage: 2)).word_display == stage2
      # The time left plays no part: only a reveal changes the mask.
      assert View.public(room(current_word: word, round_deadline: nil)).word_display == hidden
    end

    test "revealed_word is set only in :round_end" do
      for state <- [lobby(), choosing(), room([])] do
        assert View.public(state).revealed_word == nil
        assert View.delta(state).revealed_word == nil
        assert View.for_viewer(state, @p1).revealed_word == nil
      end

      ended = round_end()
      assert View.public(ended).revealed_word == @word
      assert View.delta(ended).revealed_word == @word
      assert View.for_viewer(ended, nil).revealed_word == @word
    end

    test "word_length counts letters only and is 0 without a word" do
      assert View.public(room(current_word: "ice cream")).word_length == 8
      assert View.public(room([])).word_length == 5
      assert View.public(choosing()).word_length == 0
      assert View.public(lobby()).word_length == 0
      assert View.public(choosing()).word_display == ""
    end
  end

  describe "time fields" do
    test "public/1 and delta/1 carry remaining ms and durations, no clock or schedule" do
      for state <- [lobby(), choosing(), room([]), round_end()],
          map <- [View.public(state), View.delta(state)] do
        for key <- @time_keys ++ [:word_display], do: assert(Map.has_key?(map, key))

        for key <- [:time_left, :choice_time_left, :current_word, :word_choices],
            do: refute(Map.has_key?(map, key))

        for key <- Map.keys(map), name = Atom.to_string(key) do
          refute name =~ "deadline", "#{name} in #{state.phase}"
          refute name =~ "offset", "#{name} in #{state.phase}"
        end
      end
    end

    test "round_remaining_ms counts down the :drawing phase only" do
      now = System.monotonic_time(:millisecond)
      drawing = room(round_deadline: now + 30_000)

      for map <- [View.public(drawing), View.delta(drawing)] do
        assert map.round_remaining_ms in 29_000..30_000
        assert map.choice_remaining_ms == 0
        assert map.round_duration == 80
        assert map.choice_duration == GameFlow.choice_duration()
      end

      refute dump(View.public(drawing)) =~ Integer.to_string(now + 30_000)
      assert View.public(room(round_deadline: now - 500)).round_remaining_ms == 0
      assert View.public(round_end()).round_remaining_ms == 0
      assert View.public(lobby()).round_remaining_ms == 0
    end

    test "choice_remaining_ms counts down the word choice only" do
      state = choosing()

      for map <- [View.public(state), View.delta(state), View.for_viewer(state, @drawer)] do
        assert map.choice_remaining_ms in 9_000..10_000
        assert map.round_remaining_ms == 0
        assert map.choice_duration == 15
      end

      assert View.public(room([])).choice_remaining_ms == 0
    end
  end

  describe "a player who has guessed the word (play-feedback)" do
    defp guessed(attrs \\ []) do
      room(
        [
          correct_guessers: [@p1],
          players: [
            %{id: @drawer, username: "Drawer", score: 0},
            %{id: @p1, username: "P1", score: 450},
            %{id: "p2-id", username: "P2", score: 100}
          ],
          round_start_scores: %{@drawer => 0, @p1 => 100, "p2-id" => 100}
        ] ++ attrs
      )
    end

    test "for_viewer/2 gives them the word and their points; nobody else gets either" do
      state = guessed()

      view = View.for_viewer(state, @p1)
      assert view.current_word == @word
      assert view.guess_points == 350
      assert view.is_drawer == false
      assert view.word_choices == []

      for viewer <- ["p2-id", @watcher, nil] do
        view = View.for_viewer(state, viewer)
        assert view.current_word == nil
        assert view.guess_points == nil
        refute dump(view) =~ @word
      end

      assert View.for_viewer(state, @drawer).current_word == @word
      assert View.for_viewer(state, @drawer).guess_points == nil
    end

    test "only while they are a player: a watcher id in correct_guessers gets nothing" do
      state = guessed(correct_guessers: [@watcher, @p1])
      assert View.for_viewer(state, @watcher).current_word == nil
      refute View.guessed?(state, @watcher)
      assert View.guessed?(state, @p1)
      refute View.guessed?(state, nil)
      refute View.guessed?(%{state | players: Enum.reject(state.players, &(&1.id == @p1))}, @p1)
    end

    test "public/1 and delta/1 never carry the word for them" do
      state = guessed()
      refute_leaks(View.public(state), @word)
      refute_leaks(View.delta(state), @word)
    end

    test "private_slice/2: the guesser's word and points, the drawer's as before, nothing else" do
      state = guessed()

      assert View.private_slice(state, @p1) == %{
               game_id: "TEST-game",
               round: 1,
               phase: :drawing,
               current_word: @word,
               word_choices: [],
               guess_points: 350
             }

      assert View.private_slice(state, @drawer) == View.private_slice(state)

      assert View.private_slice(state) == %{
               game_id: "TEST-game",
               round: 1,
               phase: :drawing,
               current_word: @word,
               word_choices: []
             }

      for viewer <- ["p2-id", @watcher, nil] do
        slice = View.private_slice(state, viewer)
        assert slice.current_word == nil
        refute dump(slice) =~ @word
      end
    end
  end

  describe "round_summary/1" do
    defp result(attrs) do
      Map.merge(
        %{
          round: 1,
          drawer_id: @drawer,
          drawer_name: "Drawer",
          word: @word,
          drawer_points: 275,
          player_scores: [
            %{id: @drawer, username: "Drawer", points: 275, guessed: false, is_drawer: true},
            %{id: "p0-id", username: "P0", points: 0, guessed: false, is_drawer: false},
            %{id: @p1, username: "P1", points: 200, guessed: true, is_drawer: false},
            %{id: "p2-id", username: "P2", points: 350, guessed: true, is_drawer: false}
          ],
          drawing_strokes: [%{path: "M0 0 L1 1", color: "#000000", width: 2}],
          drawing_truncated: false
        },
        Map.new(attrs)
      )
    end

    defp ended(attrs) do
      round_end(
        [
          players: [
            %{id: @drawer, username: "Drawer", score: 275},
            %{id: "p0-id", username: "P0", score: 0},
            %{id: @p1, username: "P1", score: 200},
            %{id: "p2-id", username: "P2", score: 350}
          ],
          turn_queue: [@p1, "p2-id"],
          round_results: [result([])]
        ] ++ attrs
      )
    end

    test "the answer, every player highest first, the drawer and who draws next" do
      summary = View.round_summary(ended([]))

      assert summary == %{
               round: 1,
               word: @word,
               players: [
                 %{id: "p2-id", username: "P2", points: 350, guessed: true},
                 %{id: @p1, username: "P1", points: 200, guessed: true},
                 %{id: "p0-id", username: "P0", points: 0, guessed: false}
               ],
               drawer_id: @drawer,
               drawer_name: "Drawer",
               drawer_points: 275,
               next_drawer_name: "P1"
             }

      assert View.public(ended([])).round_summary == summary
      assert View.delta(ended([])).round_summary == summary
      assert View.for_viewer(ended([]), nil).round_summary == summary
      refute dump(summary) =~ "M0 0"
    end

    test "is nil in every other phase, so the answer never goes out early" do
      for state <- [
            lobby(),
            choosing(round_results: [result([])]),
            room(round_results: [result([])])
          ] do
        assert View.round_summary(state) == nil
        assert View.public(state).round_summary == nil
        assert View.delta(state).round_summary == nil
      end
    end

    test "is nil when the round has no result (the drawer left while choosing)" do
      assert View.round_summary(ended(round_results: [result(round: 0)])) == nil
      assert View.round_summary(ended(round_results: [])) == nil
    end

    test "next drawer: the first queued drawer still in the room, none after the last round" do
      gone = ended(turn_queue: ["left-id", "p2-id"])
      assert View.round_summary(gone).next_drawer_name == "P2"

      assert View.round_summary(ended(turn_queue: [])).next_drawer_name == nil
      last = ended(current_round: 3, total_rounds: 3, round_results: [result(round: 3)])
      assert View.round_summary(last).next_drawer_name == nil
    end
  end

  defp revealed_count(display),
    do: display |> String.graphemes() |> Enum.count(&(&1 not in ["_", " "]))
end
