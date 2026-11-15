defmodule Scrawly.Games.ChoiceDifficultyTest do
  @moduledoc """
  The drawer's choices are one easy, one medium and one hard entry (see
  `Scrawly.Games.WordChoicesTest` for how they are picked). Here: the round
  takes the difficulty of the choice the drawer commits, from the room's own
  choices and never from the caller; guesses score times the difficulty's
  multiplier (easy ×1, medium ×1.25, hard ×1.5) and the drawer's points
  follow; the difficulty is saved with the round; AI words have none.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.{RoomServer, Scoring}
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @choices [{"zzyzx", :easy}, {"TESTquokka", :medium}, {"TESTfjord", :hard}]
  @drawer "drawer-id"
  @p1 "p1-id"
  @p2 "p2-id"

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp state!(room), do: :sys.get_state(pid_of(room))

  defp choosing_room do
    creator = create_user()
    player = create_user()
    room = start_room(creator)

    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(player)).next_action.name ==
             :room_resynced

    {:ok, _} = RoomServer.start_game(room.id, creator.id, %{word_choices: choices(@choices)})
    %{room: room, creator: creator, player: player}
  end

  defp choose(ctx, params) do
    GamePage.command(
      :choose_word,
      Map.put(params, :room_id, ctx.room.id),
      server_for(ctx.creator)
    )
  end

  # A room drawing `word` (with `difficulty`) in a hand-built state, guessed
  # straight away (60 of 60 s left).
  defp drawing_state(difficulty, word \\ "zzyzx") do
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
      current_word: word,
      current_difficulty: difficulty,
      round_active: true,
      round_deadline: System.monotonic_time(:millisecond) + 60_000,
      round_duration: 60,
      players: [
        %{id: @drawer, username: "Drawer", score: 0},
        %{id: @p1, username: "P1", score: 0},
        %{id: @p2, username: "P2", score: 0}
      ],
      round_start_scores: %{@drawer => 0, @p1 => 0, @p2 => 0}
    }
  end

  defp guess(state, uid, text) do
    {:reply, reply, new_state} =
      RoomServer.handle_call({:submit_message, uid, text}, {self(), make_ref()}, state)

    {reply, new_state}
  end

  defp score_of(state, id), do: Enum.find(state.players, &(&1.id == id)).score

  # ── Committing a choice ───────────────────────────────────────────────────

  describe "choosing a word" do
    test "the round takes the difficulty of the room's own choice" do
      ctx = choosing_room()

      assert choose(ctx, %{word: "TESTfjord"}).next_action.name == :private_state

      state = state!(ctx.room)

      assert {state.phase, state.current_word, state.current_difficulty} ==
               {:drawing, "TESTfjord", :hard}

      assert {:ok, %{word_difficulty: :hard}} = RoomServer.get_view(ctx.room.id, ctx.player.id)
    end

    test "a forged difficulty in the params changes nothing" do
      ctx = choosing_room()

      for forged <- ["hard", :hard, "extreme", 99, %{multiplier: 10}] do
        assert {:ok, view} = RoomServer.get_view(ctx.room.id, ctx.creator.id)
        assert view.phase == :choosing

        # A word that isn't one of the choices: denied, the room still
        # waits for a real choice.
        before = state!(ctx.room)
        result = choose(ctx, %{word: "TESTmadeup", difficulty: forged})
        assert result.next_action.name == :command_denied
        assert result.next_action.params.reason == :invalid_word
        assert state!(ctx.room) == before
      end

      # A real choice with a forged difficulty: the room's own difficulty.
      choose(ctx, %{word: "zzyzx", difficulty: "hard", multiplier: 1.5})
      assert %{current_word: "zzyzx", current_difficulty: :easy} = state!(ctx.room)
    end

    test "a choice sent as a map instead of its text is refused" do
      ctx = choosing_room()
      before = state!(ctx.room)

      result = choose(ctx, %{word: %{text: "TESTfjord", difficulty: :hard}})
      assert result.next_action.name == :command_denied
      assert state!(ctx.room) == before
    end

    test "only the drawer's commit counts, whatever difficulty a guesser sends" do
      ctx = choosing_room()

      result =
        GamePage.command(
          :choose_word,
          %{room_id: ctx.room.id, word: "TESTfjord", difficulty: "hard"},
          server_for(ctx.player)
        )

      assert result.next_action.params.reason == :not_drawer
      assert %{phase: :choosing, current_difficulty: nil} = state!(ctx.room)
    end

    test "the next turn forgets the difficulty until its word is chosen" do
      ctx = choosing_room()
      seed_test_words()
      choose(ctx, %{word: "TESTfjord"})
      assert expire_round!(ctx.room).word_difficulty == :hard

      send(pid_of(ctx.room), :auto_advance_round)
      state = state!(ctx.room)
      assert {state.phase, state.current_difficulty} == {:choosing, nil}
      assert room_state!(ctx.room.id).word_difficulty == nil
    end
  end

  # ── Scoring ───────────────────────────────────────────────────────────────

  describe "scoring" do
    test "a guess on a medium or hard word scores 1.25 or 1.5 times the easy one, rounded" do
      {{:ok, {:correct, easy}}, _} = guess(drawing_state(:easy), @p1, "zzyzx")
      assert easy == Scoring.guesser_points(60, 60, order: 1)

      {{:ok, {:correct, medium}}, _} = guess(drawing_state(:medium), @p1, "zzyzx")
      {{:ok, {:correct, hard}}, _} = guess(drawing_state(:hard), @p1, "zzyzx")

      assert medium == round(easy * 1.25)
      assert hard == round(easy * 1.5)
      assert {easy, medium, hard} == {550, 688, 825}
    end

    test "an AI word (no difficulty) scores as before" do
      {{:ok, {:correct, points}}, _} = guess(drawing_state(nil), @p1, "zzyzx")
      assert points == Scoring.guesser_points(60, 60, order: 1)
    end

    test "the chat line shows the points awarded, and the drawer's points follow" do
      {{:ok, {:correct, p1}}, state} = guess(drawing_state(:hard), @p1, "zzyzx")
      {{:ok, {:correct, p2}}, state} = guess(state, @p2, "zzyzx")

      assert p1 == round(Scoring.guesser_points(60, 60, order: 1) * 1.5)
      assert p2 == round(Scoring.guesser_points(60, 60, order: 2) * 1.5)
      assert {score_of(state, @p1), score_of(state, @p2)} == {p1, p2}

      lines = Enum.map(state.chat_messages, & &1.message)
      assert "P1 guessed the word! (+#{p1} points)" in lines
      assert "P2 guessed the word! (+#{p2} points)" in lines

      # Everyone guessed: the drawer earns the mean of the multiplied points.
      assert state.phase == :round_end
      assert score_of(state, @drawer) == Scoring.drawer_round_points([p1, p2])
      assert score_of(state, @drawer) == div(p1 + p2, 2)
    end
  end

  # ── Saved rounds ──────────────────────────────────────────────────────────

  describe "the saved round" do
    test "the round summary and the Game's round_details keep the difficulty" do
      ctx = choosing_room()
      game_id = state!(ctx.room).game_id
      choose(ctx, %{word: "TESTquokka"})

      ended = expire_round!(ctx.room)
      assert ended.round_summary.difficulty == :medium

      {:ok, _} = RoomServer.end_game(ctx.room.id)
      game = Games.get_game_by_id!(game_id)
      assert [%{"word" => "TESTquokka", "difficulty" => "medium"}] = game.round_details
    end
  end

  # ── AI rooms ──────────────────────────────────────────────────────────────

  describe "an AI room" do
    setup do
      Games.sync_words()
      :ok
    end

    test "offers its AI words without a difficulty and scores them without a bonus" do
      creator = create_user()
      player = create_user()

      room =
        start_room(creator, %{answer_kind: :words, word_source: :ai, prompt: "TEST ocean"})

      GamePage.command(:join_room, %{room_id: room.id}, server_for(player))
      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      choices = state!(room).word_choices
      assert [_, _, _] = choices
      assert Enum.all?(choices, &(&1.difficulty == nil))

      {:ok, _} = RoomServer.choose_word(room.id, creator.id, hd(choices).text)
      assert state!(room).current_difficulty == nil
      assert room_state!(room.id).word_difficulty == nil

      result =
        GamePage.command(
          :submit_guess,
          %{room_id: room.id, text: hd(choices).text},
          server_for(player)
        )

      assert %{outcome: :correct, points: points} = result.next_action.params
      assert points <= Scoring.max_points()
    end
  end
end
