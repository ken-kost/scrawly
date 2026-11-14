defmodule Scrawly.Games.RoomServer.GameFlow do
  @moduledoc """
  Pure game-flow helpers for RoomServer.

  Functions take a RoomServer state struct and return a (possibly modified) state
  struct. Side effects (PubSub, process messages, AI calls) are kept minimal —
  callers remain responsible for `bump_version` / `notify_waiters`.

  The round lifecycle has two phases:
    1. `:choosing` — drawer is shown 3 word options (`choice_duration/0` s)
    2. `:drawing`  — round timer runs; guessers submit guesses

  `start_word_choice/4` advances the Game record + drawer rotation and enters
  `:choosing`. `commit_word_choice/2` is invoked when the drawer picks or the
  choice timer expires; it calls `Games.start_round` + `Games.start_round_timer`.

  Both phases run against a monotonic deadline (`choice_deadline`,
  `round_deadline`): nothing ticks on the server. Clients count down from the
  remaining ms in `RoomServer.View`; hint stages are revealed by
  `{:hint_reveal, game_id, round, stage}` messages scheduled at commit.
  """

  alias Scrawly.Games
  alias Scrawly.Games.WordHints

  @ai_refill_threshold 6
  @max_chat_history 50
  # The drawer's word-choice window.
  @choice_duration 15

  @doc "How long, in seconds, the drawer has to pick a word before one is auto-picked."
  @spec choice_duration() :: pos_integer
  def choice_duration, do: @choice_duration

  @doc "`choice_duration/0` in ms."
  @spec choice_duration_ms() :: pos_integer
  def choice_duration_ms, do: @choice_duration * 1000

  @doc """
  Advance to the next round and enter the word-choice phase.

  Picks 3 candidate words (AI pool first, falls back to local), sets `phase:
  :choosing`, populates `word_choices`, schedules a 15s timeout via the
  supplied `schedule_timeout_fn.(game_id, round)`. Does NOT start the round
  timer — that happens in `commit_word_choice/2`.

  Returns unchanged state on any error.
  """
  def start_word_choice(state, bump_fn, notify_fn, schedule_timeout_fn) do
    player_queue = Enum.map(state.players, & &1.id)

    with {:ok, _} <- Games.complete_round(state.game_id),
         {:ok, _} <- Games.next_round(state.game_id),
         {:ok, game_with_drawer} <- Games.select_next_drawer(state.game_id, player_queue) do
      {choices, remaining_ai, used_from_ai} =
        pick_word_choices(state.ai_words, state.used_words, state.word_count, 3)

      drawer_name = get_player_name(state.players, game_with_drawer.current_drawer_id)

      new_state =
        %{
          state
          | current_round: game_with_drawer.current_round,
            current_drawer_id: game_with_drawer.current_drawer_id,
            current_word: nil,
            ai_words: remaining_ai,
            round_deadline: nil,
            hint_stage: 0,
            round_active: false,
            correct_guessers: [],
            drawing_strokes: [],
            stroke_op: nil,
            round_guesser_points: [],
            round_start_scores:
              Enum.reduce(state.players, %{}, fn p, acc ->
                Map.put(acc, p.id, p.score || 0)
              end)
        }
        |> enter_word_choice(choices, fn game_id, round ->
          schedule_timeout_fn.(game_id, round)
        end)
        |> add_sys_msg(
          "Round #{game_with_drawer.current_round} — #{drawer_name} is choosing a word …"
        )
        |> bump_fn.()
        |> notify_fn.()

      if state.word_source == :ai and used_from_ai > 0 and
           length(remaining_ai) <= @ai_refill_threshold do
        send(
          self(),
          {:refill_ai_words, state.room_id, state.word_count, state.total_rounds, state.ai_tone}
        )
      end

      new_state
    else
      _ -> state
    end
  end

  @doc """
  Set `phase: :choosing`, populate `word_choices`, set `choice_deadline`, and
  schedule the `choice_duration/0` timeout. Pure-ish: only side effect is the
  scheduled message.
  """
  def enter_word_choice(state, choices, schedule_timeout_fn) when is_list(choices) do
    deadline = System.monotonic_time(:millisecond) + choice_duration_ms()
    schedule_timeout_fn.(state.game_id, state.current_round)

    %{state | phase: :choosing, word_choices: choices, choice_deadline: deadline}
  end

  @doc """
  Commit the chosen word: persist it to the Game, start the round timer, and
  transition to `:drawing`. Returns `{:ok, state}` or `{:error, reason}`.

  Runs inside the room process: sets `round_deadline` (monotonic ms) and
  `hint_stage: 0`, and schedules one `{:hint_reveal, game_id, round, stage}`
  to `self()` per stage of `WordHints.reveal_offsets_ms/2`. The RoundTimer
  expiry carries `%{round: current_round}`.
  """
  def commit_word_choice(state, word) when is_binary(word) do
    start_round_opts = %{
      word_count: state.word_count,
      used_words: state.used_words,
      override_word: word
    }

    with {:ok, _updated_game} <-
           Games.start_round(state.game_id, state.current_drawer_id, start_round_opts),
         :ok <-
           Games.start_round_timer(state.game_id, state.round_duration, %{
             round: state.current_round
           }) do
      round_deadline = System.monotonic_time(:millisecond) + state.round_duration * 1000
      schedule_hint_reveals(state)
      drawer_name = get_player_name(state.players, state.current_drawer_id)
      new_used = Enum.uniq([word | state.used_words])

      new_state =
        %{
          state
          | current_word: word,
            word_choices: [],
            choice_deadline: nil,
            phase: :drawing,
            round_active: true,
            round_deadline: round_deadline,
            hint_stage: 0,
            used_words: new_used,
            correct_guessers: [],
            drawing_strokes: [],
            stroke_op: nil,
            round_guesser_points: []
        }
        |> add_sys_msg("Round #{state.current_round} — #{drawer_name} is drawing")

      {:ok, new_state}
    else
      err -> {:error, err}
    end
  end

  defp schedule_hint_reveals(state) do
    for {stage, offset_ms} <- WordHints.reveal_offsets_ms(state.round_duration) do
      Process.send_after(
        self(),
        {:hint_reveal, state.game_id, state.current_round, stage},
        offset_ms
      )
    end
  end

  @doc """
  Ends the game: saves results, stops timers, updates Ash resources, schedules
  a delayed self-stop via the given `send_after_fn` (to allow clients to read
  final state). Returns updated state.
  """
  def auto_end_game(state, bump_fn, notify_fn) do
    if state.game_id do
      Games.save_game_results(state.game_id, state.room_id, state.players, state.round_results)
      Games.stop_round_timer(state.game_id)
      Games.end_current_game(state.game_id)
      Games.set_room_post_game(state.room_id)
      Phoenix.PubSub.unsubscribe(Scrawly.PubSub, "game:#{state.game_id}")
    end

    game_entry = build_past_game_entry(state)

    %{
      state
      | status: :post_game,
        last_game_id: state.game_id,
        game_id: nil,
        current_round: 0,
        current_drawer_id: nil,
        current_word: nil,
        round_deadline: nil,
        hint_stage: 0,
        round_active: false,
        phase: :idle,
        word_choices: [],
        choice_deadline: nil,
        round_guesser_points: [],
        correct_guessers: [],
        drawing_strokes: [],
        stroke_op: nil,
        round_results: [],
        used_words: [],
        ai_words: [],
        chat_messages: [],
        past_games: [game_entry | state.past_games]
    }
    |> add_sys_msg("Game over! Final scores are in.")
    |> bump_fn.()
    |> notify_fn.()
  end

  @doc """
  Appends a round result entry to `state.round_results`. drawer_points is the
  points awarded (or deducted) from the drawer this round.
  """
  def capture_round_result(state, drawer_points) do
    player_scores =
      Enum.map(state.players, fn p ->
        start_score = Map.get(state.round_start_scores, p.id, 0)
        points_this_round = (p.score || 0) - start_score

        %{
          id: p.id,
          username: p.username,
          points: points_this_round,
          guessed: p.id in state.correct_guessers,
          is_drawer: p.id == state.current_drawer_id
        }
      end)

    result = %{
      round: state.current_round,
      drawer_id: state.current_drawer_id,
      drawer_name: get_player_name(state.players, state.current_drawer_id),
      word: state.current_word,
      drawer_points: drawer_points,
      player_scores: player_scores,
      drawing_strokes: state.drawing_strokes
    }

    %{state | round_results: state.round_results ++ [result]}
  end

  @doc "Returns the username for a player by ID, or \"Unknown\" if not found."
  def get_player_name(players, player_id) do
    case Enum.find(players, &(&1.id == player_id)) do
      nil -> "Unknown"
      p -> p.username
    end
  end

  @doc "Builds a summary entry for a completed game."
  def build_past_game_entry(state) do
    sorted = Enum.sort_by(state.players, & &1.score, :desc)
    winner = List.first(sorted)

    %{
      game_id: state.game_id,
      total_rounds: state.total_rounds,
      players: Enum.map(sorted, fn p -> %{username: p.username, score: p.score || 0} end),
      winner:
        if(winner,
          do: %{username: winner.username, score: winner.score || 0},
          else: nil
        )
    }
  end

  @doc """
  Prepends a server-built chat line to state.chat_messages (capped at 50) and
  broadcasts it. `type` is `:system` or `:correct_guess`; these lines only ever
  come from the room process, never from client input.
  """
  def add_sys_msg(state, text, type \\ :system) do
    push_chat(state, %{player_name: "System", message: text, type: type})
  end

  @doc """
  The only place a chat line enters a room: stamps `fields` with a unique `id`
  and an integer `timestamp` (Unix ms), broadcasts it as `:chat_appended`
  (`%{message: msg}`) and prepends it to `state.chat_messages` (capped at 50).

  Chat lines reach the browser through room state and that broadcast, so they
  hold plain data only: a struct (a DateTime, say) would make every client
  load that type's code chunk before it can show the line.
  """
  def push_chat(state, fields) when is_map(fields) do
    msg =
      Map.merge(fields, %{
        id: System.unique_integer([:positive]),
        timestamp: System.system_time(:millisecond)
      })

    Hologram.Realtime.broadcast_action({:room, state.room_id}, :chat_appended, %{message: msg})

    %{state | chat_messages: Enum.take([msg | state.chat_messages], @max_chat_history)}
  end

  @doc """
  Pick `count` candidate words for the drawer, preferring the AI pool, falling
  back to local DB if the pool is exhausted.

  Returns `{choices, remaining_ai_pool, used_from_ai_count}`.
  """
  def pick_word_choices(ai_pool, used_words, word_count, count) do
    {from_ai, remaining_ai} = pop_n(ai_pool, count)
    needed = count - length(from_ai)

    local =
      if needed > 0 do
        pick_local_words(used_words ++ from_ai, word_count, needed)
      else
        []
      end

    choices = from_ai ++ local
    {Enum.uniq(choices), remaining_ai, length(from_ai)}
  end

  defp pop_n(list, n) when n > 0 do
    {taken, rest} = Enum.split(list, n)
    {taken, rest}
  end

  defp pop_n(list, _), do: {[], list}

  defp pick_local_words(exclude, word_count, count) do
    Enum.reduce_while(1..count, {[], exclude}, fn _, {acc, excl} ->
      case Games.get_random_word(exclude: excl, word_count: word_count) do
        {:ok, word} ->
          if word in acc do
            {:halt, {acc, excl}}
          else
            {:cont, {[word | acc], [word | excl]}}
          end

        _ ->
          {:halt, {acc, excl}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
