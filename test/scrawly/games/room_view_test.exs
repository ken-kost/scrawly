defmodule Scrawly.Games.RoomViewTest do
  @moduledoc """
  `RoomServer.View` decides what each viewer may see. Only the drawer's view
  ever carries the word or the word choices.
  """
  use ExUnit.Case, async: true

  alias Scrawly.Games.{RoomServer, WordHints}
  alias Scrawly.Games.RoomServer.View

  @word "zzyzx"
  @choices ["zzyzx", "quokka", "fjord"]
  @drawer "drawer-id"
  @p1 "p1-id"
  @watcher "watcher-id"
  @secret_keys [:current_word, :word_choices, :choice_deadline]

  # Every key GamePage reads from a :room_refreshed reply with dot access, plus
  # the word fields it reads with Map.get.
  @viewer_keys [
    :is_drawer,
    :drawer_name,
    :current_word,
    :word_choices,
    :word_display,
    :word_length,
    :revealed_word,
    :choice_time_left,
    :status,
    :game_id,
    :last_game_id,
    :players,
    :max_players,
    :version,
    :correct_guessers,
    :chat_messages,
    :watchers,
    :past_games,
    :current_round,
    :total_rounds,
    :current_drawer_id,
    :time_left,
    :phase,
    :drawing_strokes
  ]

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
        time_left: 80,
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
      time_left: 0
    )
  end

  defp dump(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp refute_leaks(map, words) do
    for word <- List.wrap(words), do: refute(dump(map) =~ word)
    for key <- @secret_keys, do: refute(Map.has_key?(map, key))
  end

  describe "public/1 and delta/1" do
    test "never carry the word while drawing, whatever the hint stage" do
      for time_left <- [80, 50, 25, 0] do
        state = room(time_left: time_left)
        refute_leaks(View.public(state), @word)
        refute_leaks(View.delta(state), @word)
      end
    end

    test "carry no candidate word while choosing" do
      state = choosing()
      refute_leaks(View.public(state), @choices)
      refute_leaks(View.delta(state), @choices)
      assert View.public(state).choice_time_left in 1..10
      assert View.delta(state).choice_time_left in 1..10
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
            [:name, :code, :players, :max_players, :status, :word_count, :word_source] ++
              [:prompt, :ai_tone, :round_multiplier, :round_duration, :chat_messages] do
        assert Map.has_key?(public, key)
      end
    end
  end

  describe "for_viewer/2" do
    test "gives guessers, watchers and visitors no word and no choices" do
      for state <- [room([]), choosing(), room(phase: :round_end, time_left: 0)],
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
      for state <- [lobby(), choosing(), room([]), room(phase: :round_end, time_left: 0)],
          viewer <- [@drawer, @p1, nil],
          key <- @viewer_keys do
        assert Map.has_key?(View.for_viewer(state, viewer), key),
               "#{inspect(key)} missing for #{inspect(viewer)} in #{state.phase}"
      end
    end
  end

  describe "word fields" do
    test "word_display changes stage at 37.5% and 68.75% of the round elapsed" do
      word = "watermelon"
      display = fn time_left -> View.public(room(current_word: word, time_left: time_left)) end

      hidden = display.(80).word_display
      assert hidden == "_ _ _ _ _ _ _ _ _ _"
      assert display.(51).word_display == hidden

      stage1 = display.(50).word_display
      assert stage1 != hidden
      assert stage1 == WordHints.generate_hint(word, 50, 80)
      assert display.(26).word_display == stage1

      stage2 = display.(25).word_display
      assert stage2 != stage1
      assert revealed_count(stage1) < revealed_count(stage2)
      refute stage2 =~ word

      assert View.delta(room(current_word: word, time_left: 25)).word_display == stage2
    end

    test "revealed_word is set only in :round_end" do
      for state <- [lobby(), choosing(), room([])] do
        assert View.public(state).revealed_word == nil
        assert View.delta(state).revealed_word == nil
        assert View.for_viewer(state, @p1).revealed_word == nil
      end

      ended = room(phase: :round_end, time_left: 0, round_active: false)
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

  describe "RoomServer tick" do
    test "the 1 Hz :room_delta carries the current hint, never the word" do
      state = room(time_left: 80)
      topic = Hologram.Realtime.channel_topic({:room, state.room_id})
      Phoenix.PubSub.subscribe(Hologram.PubSub, topic)

      {:noreply, _} = RoomServer.handle_info({:timer_update, %{remaining_seconds: 0}}, state)

      assert_received {:broadcast_action, _, :room_delta, delta, _}
      assert delta.word_display == WordHints.generate_hint(@word, 0, 80)
      assert delta.word_display =~ ~r/[a-z]/
      refute_leaks(delta, @word)
    end
  end

  defp revealed_count(display),
    do: display |> String.graphemes() |> Enum.count(&(&1 not in ["_", " "]))
end
