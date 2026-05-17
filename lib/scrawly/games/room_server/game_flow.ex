defmodule Scrawly.Games.RoomServer.GameFlow do
  @moduledoc """
  Pure game-flow helpers for RoomServer.

  All functions take a RoomServer state struct and return a (possibly modified)
  state struct. Side effects (PubSub, process messages) are kept to the minimum
  needed — callers remain responsible for `bump_version/notify_waiters`.
  """

  alias Scrawly.Games

  # Trigger async AI word refill when the pool drops at or below this count.
  @ai_refill_threshold 2

  @doc """
  Advances to the next round. Selects the next word and drawer, starts the timer,
  and returns updated state. Returns unchanged state on any error.

  Tracks used words to prefer fresh words each round (DB source).
  Triggers async AI word refill (via `notify_fn`) when the AI pool runs low.
  """
  def auto_next_round(state, bump_fn, notify_fn) do
    player_queue = Enum.map(state.players, & &1.id)

    {override_word, remaining_ai_words} =
      case state.ai_words do
        [next | rest] -> {next, rest}
        _ -> {nil, []}
      end

    start_round_opts =
      %{word_count: state.word_count, used_words: state.used_words}
      |> then(fn opts ->
        if override_word, do: Map.put(opts, :override_word, override_word), else: opts
      end)

    with {:ok, _} <- Games.complete_round(state.game_id),
         {:ok, _} <- Games.next_round(state.game_id),
         {:ok, game_with_drawer} <- Games.select_next_drawer(state.game_id, player_queue),
         {:ok, final_game} <-
           Games.start_round(state.game_id, game_with_drawer.current_drawer_id, start_round_opts),
         :ok <- Games.start_round_timer(state.game_id, state.round_duration) do
      drawer_name = get_player_name(state.players, final_game.current_drawer_id)
      new_word = final_game.current_word
      new_used = if new_word, do: Enum.uniq([new_word | state.used_words]), else: state.used_words

      new_state =
        %{
          state
          | current_round: final_game.current_round,
            current_drawer_id: final_game.current_drawer_id,
            current_word: new_word,
            ai_words: remaining_ai_words,
            used_words: new_used,
            time_left: state.round_duration,
            round_active: true,
            correct_guessers: [],
            drawing_strokes: [],
            round_start_scores:
              Enum.reduce(state.players, %{}, fn p, acc -> Map.put(acc, p.id, p.score || 0) end)
        }
        |> add_sys_msg("Round #{final_game.current_round} \u2014 #{drawer_name} is drawing")
        |> bump_fn.()
        |> notify_fn.()

      # Trigger async AI word refill if pool is running low
      if state.word_source == :ai and length(remaining_ai_words) <= @ai_refill_threshold do
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

    # Build past game entry before clearing state
    game_entry = build_past_game_entry(state)

    %{
      state
      | status: :post_game,
        last_game_id: state.game_id,
        game_id: nil,
        current_round: 0,
        current_drawer_id: nil,
        current_word: nil,
        time_left: 0,
        round_active: false,
        correct_guessers: [],
        drawing_strokes: [],
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

  @doc "Prepends a system chat message to state.chat_messages (capped at 50)."
  def add_sys_msg(state, text) do
    msg = %{
      id: :rand.uniform(100_000),
      player_name: "System",
      message: text,
      timestamp: DateTime.utc_now(),
      type: :system
    }

    %{state | chat_messages: [msg | state.chat_messages] |> Enum.take(50)}
  end
end
