defmodule Scrawly.Games.RoomServer.GameFlow do
  @moduledoc """
  Pure game-flow helpers for RoomServer.

  Functions take a RoomServer state struct and return a (possibly modified) state
  struct. Side effects (PubSub, process messages, AI calls) are kept minimal —
  callers remain responsible for `notify_waiters` (the `:room_delta`). Chat
  lines are published here (`push_chat/2`), through
  `RoomServer.Broadcasts.publish/3` like every `{:room}` broadcast.

  The round lifecycle has two phases:
    1. `:choosing` — drawer is shown 3 word options (`choice_duration/0` s)
    2. `:drawing`  — the round runs; guessers submit guesses

  `start_word_choice/3` advances the Game record, takes the next drawer from
  the room's turn queue (`turn_queue`, built at game start) and enters
  `:choosing`. `commit_word_choice/2` is invoked when the drawer picks or the
  choice timer expires; it calls `Games.start_round` and schedules the round's
  own expiry.

  Both phases run against a monotonic deadline (`choice_deadline`,
  `round_deadline`): nothing ticks on the server. Clients count down from the
  remaining ms in `RoomServer.View`. The room process times its turns itself
  with `Process.send_after/3` (no shared timer process that could lose them):
  the choice timeout, the round's `{:round_ended, %{game_id, round, reason:
  :time_up}}` expiry, the `{:hint_reveal, game_id, round, stage}` reveals and
  the `:auto_advance_round` after a round ends. Their refs are kept in
  `turn_timers` (`track_timer/2`) and cancelled whenever the turn or the game
  ends (`cancel_turn_timers/1`); the handlers also check game, round and
  phase, so a timer that fired anyway changes nothing.
  """

  alias Scrawly.Games
  alias Scrawly.Games.{AiWords, AnswerKind, Guess, StrokeRules, Word, WordHints}
  alias Scrawly.Games.RoomServer.Broadcasts

  @ai_refill_threshold 6
  @max_chat_history 50
  # Finished games a room remembers (shown in its lobby, sent in snapshots).
  @max_past_games 5
  # The drawer's word-choice window.
  @choice_duration 15

  @doc "How long, in seconds, the drawer has to pick a word before one is auto-picked."
  @spec choice_duration() :: pos_integer
  def choice_duration, do: @choice_duration

  @doc "`choice_duration/0` in ms."
  @spec choice_duration_ms() :: pos_integer
  def choice_duration_ms, do: @choice_duration * 1000

  @doc "How many finished games a room keeps in `past_games`."
  @spec max_past_games() :: pos_integer
  def max_past_games, do: @max_past_games

  @doc """
  Remembers `ref` (a `Process.send_after/3` ref) as one of the current turn's
  timers, so `cancel_turn_timers/1` can cancel it. Anything else is ignored.
  """
  def track_timer(state, ref) when is_reference(ref),
    do: %{state | turn_timers: [ref | state.turn_timers]}

  def track_timer(state, _not_a_ref), do: state

  @doc "Cancels every timer of the current turn (`track_timer/2`)."
  def cancel_turn_timers(state) do
    Enum.each(state.turn_timers, &Process.cancel_timer/1)
    %{state | turn_timers: []}
  end

  @doc """
  Advance to the next round and enter the word-choice phase.

  The drawer is the first player of `turn_queue` (the turn order built at
  game start, from which a leaver's turns are removed), so nobody is skipped
  or draws twice when someone leaves. Picks 3 candidate words of the room's
  answer kind (`pick_word_choices/4`: AI pool first, then the local words,
  which fall back to the built-in list), sets
  `phase: :choosing`, and schedules the `choice_duration/0` timeout via
  `schedule_timeout_fn.(game_id, round)` (which returns the timer ref).
  `notify_fn` runs last, on the new state (the room's `:room_delta`, then the
  drawer's private slice).

  Returns `{:ok, state}`, or `{:error, reason}` when the round can't start
  (no drawer left, a failed Game update, no words): the caller ends the game
  instead of leaving the room stuck between rounds.
  """
  def start_word_choice(state, notify_fn, schedule_timeout_fn) do
    state = cancel_turn_timers(state)

    with {:ok, drawer_id, queue} <- next_drawer(state),
         {:ok, _} <- Games.complete_round(state.game_id),
         {:ok, _} <- Games.next_round(state.game_id),
         {[_ | _] = choices, remaining_ai, used_from_ai} <-
           pick_word_choices(state.ai_words, state.used_words, state.answer_kind, 3) do
      round = state.current_round + 1
      drawer_name = get_player_name(state.players, drawer_id)

      new_state =
        %{
          state
          | current_round: round,
            current_drawer_id: drawer_id,
            turn_queue: queue,
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
        |> enter_word_choice(choices, schedule_timeout_fn)
        |> add_sys_msg("Round #{round} — #{drawer_name} is choosing a word …")
        |> notify_fn.()

      if state.word_source == :ai and used_from_ai > 0 and
           length(remaining_ai) <= @ai_refill_threshold do
        send(self(), {:refill_ai_words, state.room_id, state.total_rounds, state.ai_tone})
      end

      {:ok, new_state}
    else
      {:error, reason} -> {:error, reason}
      {[], _remaining_ai, _used} -> {:error, :no_words}
      other -> {:error, other}
    end
  end

  # The next drawer still in the room, and the turns after theirs.
  defp next_drawer(state) do
    ids = MapSet.new(state.players, & &1.id)

    case Enum.drop_while(state.turn_queue, &(not MapSet.member?(ids, &1))) do
      [drawer_id | rest] -> {:ok, drawer_id, rest}
      [] -> {:error, :no_drawer}
    end
  end

  @doc """
  Set `phase: :choosing`, populate `word_choices`, set `choice_deadline`, and
  schedule the `choice_duration/0` timeout (`schedule_timeout_fn` returns its
  ref, which joins the turn's timers).
  """
  def enter_word_choice(state, choices, schedule_timeout_fn) when is_list(choices) do
    deadline = System.monotonic_time(:millisecond) + choice_duration_ms()
    ref = schedule_timeout_fn.(state.game_id, state.current_round)

    %{state | phase: :choosing, word_choices: choices, choice_deadline: deadline}
    |> track_timer(ref)
  end

  @doc """
  Commit the chosen word: persist it to the Game and transition to
  `:drawing`. Returns `{:ok, state}` or `{:error, reason}`.

  Runs inside the room process: cancels the choice timeout, sets
  `round_deadline` (monotonic ms) and `hint_stage: 0`, and schedules to
  `self()` the round's expiry, `{:round_ended, %{game_id, round, reason:
  :time_up}}` after `round_duration` seconds, and one `{:hint_reveal,
  game_id, round, stage}` per stage of `WordHints.reveal_offsets_ms/2`.
  """
  def commit_word_choice(state, word) when is_binary(word) do
    start_round_opts = %{used_words: state.used_words, override_word: word}

    case Games.start_round(state.game_id, state.current_drawer_id, start_round_opts) do
      {:ok, _updated_game} ->
        round_ms = round(state.round_duration * 1000)
        drawer_name = get_player_name(state.players, state.current_drawer_id)

        expiry =
          Process.send_after(
            self(),
            {:round_ended,
             %{game_id: state.game_id, round: state.current_round, reason: :time_up}},
            round_ms
          )

        new_state =
          %{
            state
            | current_word: word,
              word_choices: [],
              choice_deadline: nil,
              phase: :drawing,
              round_active: true,
              round_deadline: System.monotonic_time(:millisecond) + round_ms,
              hint_stage: 0,
              used_words: Enum.uniq([word | state.used_words]),
              correct_guessers: [],
              drawing_strokes: [],
              stroke_op: nil,
              round_guesser_points: []
          }
          |> cancel_turn_timers()
          |> track_timer(expiry)
          |> schedule_hint_reveals()
          |> add_sys_msg("Round #{state.current_round} — #{drawer_name} is drawing")

        {:ok, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_hint_reveals(state) do
    Enum.reduce(WordHints.reveal_offsets_ms(state.round_duration), state, fn {stage, offset_ms},
                                                                             acc ->
      ref =
        Process.send_after(
          self(),
          {:hint_reveal, state.game_id, state.current_round, stage},
          offset_ms
        )

      track_timer(acc, ref)
    end)
  end

  @doc """
  Ends the game: cancels the turn's timers, saves the results, marks the Game
  `:completed` and the room `:post_game`, and remembers the game in
  `past_games` (the newest `max_past_games/0`). Posts "Game over!" and, when
  given, `reason` (why it ended early), then runs `notify_fn`. Returns the
  updated state.
  """
  def auto_end_game(state, notify_fn, reason \\ nil) do
    state = cancel_turn_timers(state)

    if state.game_id do
      Games.save_game_results(state.game_id, state.room_id, state.players, state.round_results)
      Games.end_current_game(state.game_id)
      Games.set_room_post_game(state.room_id)
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
        turn_queue: [],
        chat_messages: [],
        past_games: Enum.take([game_entry | state.past_games], @max_past_games)
    }
    |> add_sys_msg("Game over! Final scores are in.")
    |> then(&if(reason, do: add_sys_msg(&1, reason), else: &1))
    |> notify_fn.()
  end

  @doc """
  Appends a round result entry to `state.round_results`. drawer_points is the
  points awarded (or deducted) from the drawer this round. `drawer_name`
  overrides the name looked up in `players` (a drawer who just left).

  The drawing is kept as its replay (`StrokeRules.replay/1`: the first
  strokes up to the stroke and byte caps, without ids), with
  `drawing_truncated` telling whether strokes were left out: the results are
  saved in one JSONB update and the score page renders every round.
  """
  def capture_round_result(state, drawer_points, drawer_name \\ nil) do
    {replay, truncated?} = StrokeRules.replay(state.drawing_strokes)

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
      drawer_name: drawer_name || get_player_name(state.players, state.current_drawer_id),
      word: state.current_word,
      drawer_points: drawer_points,
      player_scores: player_scores,
      drawing_strokes: replay,
      drawing_truncated: truncated?
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
  The only place a chat line enters a room: stamps `fields` with an `id` and
  an integer `timestamp` (Unix ms), publishes it as `:chat_appended`
  (`%{message: msg, seq: seq}`) and prepends it to `state.chat_messages`
  (capped at 50).

  The id is the line's broadcast seq (`Broadcasts.publish/3`): unique within
  the room and increasing, so pages can merge chat from a snapshot with lines
  that arrived after it.

  Chat lines reach the browser through room state and that broadcast, so they
  hold plain data only: a struct (a DateTime, say) would make every client
  load that type's code chunk before it can show the line.
  """
  def push_chat(state, fields) when is_map(fields) do
    msg = Map.merge(fields, %{id: state.seq + 1, timestamp: System.system_time(:millisecond)})
    state = Broadcasts.publish(state, :chat_appended, %{message: msg})

    %{state | chat_messages: Enum.take([msg | state.chat_messages], @max_chat_history)}
  end

  @doc """
  Pick `count` candidate words for the drawer of a room of kind
  `answer_kind` (`Scrawly.Games.AnswerKind`): only words for `:words`, only
  phrases for `:phrases`, and exactly one phrase among words, at a random
  position, for `:mixed`.

  Every choice comes from the AI pool when it holds one of the right kind,
  then from the local words of that kind (`Games.get_random_word/1`, which
  falls back to the built-in list when the DB has none), then from the
  built-in list directly, so the choices are never empty. The pool goes
  through `AiWords.filter/2` first, so whatever it holds, nothing the room
  can't offer is ever picked or kept; words in `used_words` (compared by
  `Guess.key/1`) are dropped from it too.

  Returns `{choices, remaining_ai_pool, used_from_ai_count}`.
  """
  def pick_word_choices(ai_pool, used_words, answer_kind, count) do
    used = MapSet.new(used_words, &Guess.key/1)

    pool =
      ai_pool
      |> AiWords.filter(answer_kind)
      |> Enum.reject(&MapSet.member?(used, Guess.key(&1)))

    # One AI entry of the slot's kind per slot; `{:local, kind}` where the
    # pool has none left.
    {slots, remaining_ai} =
      answer_kind
      |> AnswerKind.slots(count)
      |> Enum.map_reduce(pool, fn kind, pool ->
        case Enum.split_while(pool, &(AnswerKind.of(&1) != kind)) do
          {skipped, [word | rest]} -> {word, skipped ++ rest}
          {_all, []} -> {{:local, kind}, pool}
        end
      end)

    from_ai = Enum.filter(slots, &is_binary/1)
    local_words = pick_local_words(:word, count_local(slots, :word), used_words, from_ai)

    local_phrases =
      pick_local_words(:phrase, count_local(slots, :phrase), used_words, from_ai ++ local_words)

    {choices, _left} =
      Enum.map_reduce(slots, {local_words, local_phrases}, fn
        {:local, :word}, {[word | words], phrases} -> {word, {words, phrases}}
        {:local, :phrase}, {words, [phrase | phrases]} -> {phrase, {words, phrases}}
        {:local, _kind}, left -> {nil, left}
        word, left -> {word, left}
      end)

    {choices |> Enum.reject(&is_nil/1) |> Enum.uniq_by(&Guess.key/1), remaining_ai,
     length(from_ai)}
  end

  defp count_local(slots, kind), do: Enum.count(slots, &(&1 == {:local, kind}))

  # `count` words of `kind` that share no `Guess.key/1` with the set's
  # other choices (`set`) or each other, avoiding `used` ones unless nothing
  # else is left: at most `count` * 4 lookups, topped up from the built-in
  # list.
  defp pick_local_words(_kind, 0, _used, _set), do: []

  defp pick_local_words(kind, count, used, set) do
    picked =
      Enum.reduce_while(1..(count * 4), [], fn _attempt, acc ->
        if length(acc) >= count do
          {:halt, acc}
        else
          case Games.get_random_word(exclude: used ++ set ++ acc, kind: kind) do
            {:ok, word} -> {:cont, if(clashes?(word, set ++ acc), do: acc, else: [word | acc])}
            _error -> {:cont, acc}
          end
        end
      end)
      |> Enum.reverse()

    picked ++ builtin_top_up(kind, count - length(picked), used, set ++ picked)
  end

  defp builtin_top_up(_kind, missing, _used, _set) when missing <= 0, do: []

  defp builtin_top_up(kind, missing, used, set) do
    {used, set} = {MapSet.new(used, &Guess.key/1), MapSet.new(set, &Guess.key/1)}

    {fresh, stale} =
      kind
      |> Word.builtin_words()
      |> Enum.map(&{&1, Guess.key(&1)})
      |> Enum.reject(fn {_word, key} -> MapSet.member?(set, key) end)
      |> Enum.split_with(fn {_word, key} -> not MapSet.member?(used, key) end)

    (Enum.shuffle(fresh) ++ Enum.shuffle(stale))
    |> Enum.take(missing)
    |> Enum.map(fn {word, _key} -> word end)
  end

  defp clashes?(word, words) do
    key = Guess.key(word)
    Enum.any?(words, &(Guess.key(&1) == key))
  end
end
