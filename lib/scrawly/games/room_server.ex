defmodule Scrawly.Games.RoomServer do
  @moduledoc """
  GenServer representing a game room. Single source of truth for room membership,
  game state, chat messages, and drawing data. State changes are projected to
  subscribed game pages via Hologram realtime (`:room_delta` / `:chat_appended`).

  Rounds run against monotonic deadlines (`round_deadline`, `choice_deadline`):
  the room broadcasts the remaining ms in its deltas and clients count down
  locally, so nothing is pushed while a countdown runs. It subscribes to the
  game's RoundTimer topic for the one-shot `{:round_ended, ...}` expiry and
  reveals hint stages from its own `{:hint_reveal, ...}` messages. Auto-advances
  rounds when the timer expires or all players guess correctly.
  """
  use GenServer

  alias Scrawly.Games

  alias Scrawly.Games.{
    Guess,
    Scoring,
    StrokeRules,
    WordHints,
    RoomServer.GameFlow,
    RoomServer.View
  }

  @registry Scrawly.RoomRegistry
  @supervisor Scrawly.RoomSupervisor
  @max_watchers 50
  @max_message_length 240
  @chat_max_messages 3
  @chat_window_ms 5_000
  # How long a finished game's score page shows before the room returns to the
  # lobby (`:return_to_lobby`).
  @post_game_ms 30_000

  defstruct [
    :room_id,
    :name,
    :code,
    :status,
    :creator_id,
    :max_players,
    players: [],
    watchers: [],
    version: 0,
    word_count: 1,
    word_source: :local,
    prompt: nil,
    creator_name: nil,
    round_duration: 60,
    round_multiplier: 1,
    ai_tone: :fun,
    ai_words: [],
    used_words: [],
    game_id: nil,
    current_round: 0,
    total_rounds: 5,
    current_drawer_id: nil,
    current_word: nil,
    # Monotonic ms (node-local) at which the :drawing phase times out; nil in
    # every other phase. Never sent: View sends the remaining ms.
    round_deadline: nil,
    # Hint batches revealed this round (WordHints.hint_for_stage/3), set by
    # {:hint_reveal, ...}.
    hint_stage: 0,
    round_active: false,
    correct_guessers: [],
    last_game_id: nil,
    phase: :idle,
    word_choices: [],
    choice_deadline: nil,
    # Monotonic ms (node-local, like choice_deadline) at which a :post_game
    # room returns to the lobby; nil in every other status.
    post_game_deadline: nil,
    round_guesser_points: [],
    round_results: [],
    round_start_scores: %{},
    chat_messages: [],
    drawing_strokes: [],
    stroke_op: nil,
    chat_rate_limits: %{},
    past_games: []
  ]

  @doc """
  The room's process, started from the DB if it isn't running.
  `{:error, :room_not_found}` for an unknown id, `{:error, :room_ended}` for a
  dissolved room.
  """
  def ensure_started(room_id) do
    case Registry.lookup(@registry, room_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(@supervisor, {__MODULE__, room_id})
        |> case do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  @doc """
  How long, in ms, a room stays in `:post_game` (the score page's countdown)
  before it returns to the lobby.
  """
  @spec post_game_ms() :: pos_integer
  def post_game_ms, do: @post_game_ms

  def start_link(room_id), do: GenServer.start_link(__MODULE__, room_id, name: via(room_id))

  def child_spec(room_id) do
    %{id: {__MODULE__, room_id}, start: {__MODULE__, :start_link, [room_id]}, restart: :temporary}
  end

  @doc """
  The room as anyone may see it (`View.public/1`): never the word or the word
  choices. Use `get_view/2` for what a given viewer's page needs.
  """
  def get_state(room_id) do
    GenServer.call(via(room_id), :get_state)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  The room as `viewer_id` may see it (`View.for_viewer/2`): the word and the
  word choices are included only when `viewer_id` is the current drawer. Pass
  the session user's id, or `nil` for visitors without an account.
  """
  @spec get_view(term, term) :: {:ok, map} | {:error, :not_found}
  def get_view(room_id, viewer_id) do
    GenServer.call(via(room_id), {:get_view, viewer_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def join(room_id, player) do
    GenServer.call(via(room_id), {:join, player})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def leave(room_id, player_id) do
    GenServer.call(via(room_id), {:leave, player_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def join_as_watcher(room_id, watcher) do
    GenServer.call(via(room_id), {:join_watcher, watcher})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def leave_watcher(room_id, watcher_id) do
    GenServer.call(via(room_id), {:leave_watcher, watcher_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def update_player_score(room_id, player_id, points) do
    GenServer.call(via(room_id), {:update_player_score, player_id, points})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Starts a game on behalf of `actor_id`.

  Re-checks `authorize/3` inside the room process, so two concurrent starts
  cannot both pass. The drawer (first player) and the round count come from the
  room's own player list, never from the caller. Persists the room status and
  the Game row before touching room state.

  `opts` may carry `:word_choices` (first round's choices) and `:ai_words` (the
  remaining AI pool). Returns `{:ok, public_state}` or `{:error, reason}`.
  """
  def start_game(room_id, actor_id, opts \\ %{}) do
    GenServer.call(via(room_id), {:start_game, actor_id, Map.new(opts)})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Submits a chat line typed by `user_id`. Guesses are checked here, in the room
  process, so scoring is atomic and guess order is deterministic.

  The text is trimmed and capped at #{@max_message_length} characters. The
  sender must be a player or a watcher; the displayed name is always the stored
  username. Every sender is limited to #{@chat_max_messages} messages per
  #{@chat_window_ms} ms, guesses included.

  Replies:

    * `{:ok, {:correct, points}}` - a non-drawer player guessed the word while
      `:drawing` (first time this round). The text is not stored; a
      `:correct_guess` line is posted instead.
    * `{:ok, :suppressed}` - the word, typed by a player who already guessed or
      by a watcher. Nothing is stored or broadcast.
    * `{:ok, :chat}` - anything else, stored and broadcast as `:chat`.
    * `{:error, :empty | :not_in_room | :rate_limited | :drawer_cannot_chat |
      :not_found}` - nothing changes.
  """
  @spec submit_message(term, term, term) ::
          {:ok, {:correct, pos_integer} | :suppressed | :chat}
          | {:error, :empty | :not_in_room | :rate_limited | :drawer_cannot_chat | :not_found}
  def submit_message(room_id, user_id, text) do
    GenServer.call(via(room_id), {:submit_message, user_id, text})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Posts a server-side `:system` line to the room chat (e.g. the AI word status).
  Never call this with client-provided text.
  """
  def system_message(room_id, text) when is_binary(text) do
    GenServer.call(via(room_id), {:system_message, text})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def choose_word(room_id, player_id, word) do
    GenServer.call(via(room_id), {:choose_word, player_id, word})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def end_game(room_id) do
    GenServer.call(via(room_id), :end_game)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Dissolves the room when `actor_id` is its creator; `{:error, :not_creator}`
  otherwise.
  """
  def dissolve_room(room_id, actor_id) do
    GenServer.call(via(room_id), {:dissolve_room, actor_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Pure authorization check for room commands against a room state (the struct
  or the map returned by `get_state/1`).

    * `:start_game` - the actor is the creator, the room is in `:lobby` with no
      game, and there are at least 2 players.
    * `:dissolve` - the actor is the creator.
    * `:leave` - the actor is a player or the creator.
    * `:draw` - the actor is the current drawer (`:not_drawer`) and the room
      is in `:drawing` (`:wrong_phase`). Covers strokes, clear and undo.
  """
  @spec authorize(map, term, :start_game | :dissolve | :leave | :draw) :: :ok | {:error, atom}
  def authorize(state, actor_id, :start_game) do
    cond do
      not creator?(state, actor_id) -> {:error, :not_creator}
      state.status != :lobby or state.game_id != nil -> {:error, :wrong_state}
      length(state.players) < 2 -> {:error, :not_enough_players}
      true -> :ok
    end
  end

  def authorize(state, actor_id, :dissolve) do
    if creator?(state, actor_id), do: :ok, else: {:error, :not_creator}
  end

  def authorize(state, actor_id, :leave) do
    if creator?(state, actor_id) or player?(state, actor_id),
      do: :ok,
      else: {:error, :not_member}
  end

  def authorize(state, actor_id, :draw) do
    cond do
      not (is_binary(actor_id) and actor_id == state.current_drawer_id) -> {:error, :not_drawer}
      state.phase != :drawing -> {:error, :wrong_phase}
      true -> :ok
    end
  end

  @doc """
  Ms left in the `:drawing` phase (never negative), 0 when no round deadline
  is set. `now` is `System.monotonic_time(:millisecond)` on this node.
  """
  @spec round_remaining_ms(map, integer) :: non_neg_integer
  def round_remaining_ms(state, now \\ System.monotonic_time(:millisecond))

  def round_remaining_ms(%{round_deadline: deadline}, now) when is_integer(deadline),
    do: max(0, deadline - now)

  def round_remaining_ms(_state, _now), do: 0

  @doc "Ms left to pick a word (never negative), 0 outside `:choosing`."
  @spec choice_remaining_ms(map, integer) :: non_neg_integer
  def choice_remaining_ms(state, now \\ System.monotonic_time(:millisecond))

  def choice_remaining_ms(%{choice_deadline: deadline}, now) when is_integer(deadline),
    do: max(0, deadline - now)

  def choice_remaining_ms(_state, _now), do: 0

  @doc """
  Whole seconds left in the round, rounded up (what a client countdown shows):
  the time used for guess scoring.
  """
  @spec time_left(map, integer) :: non_neg_integer
  def time_left(state, now \\ System.monotonic_time(:millisecond)),
    do: div(round_remaining_ms(state, now) + 999, 1000)

  defp creator?(state, actor_id), do: actor_id != nil and actor_id == state.creator_id
  defp player?(state, actor_id), do: Enum.any?(state.players, &(&1.id == actor_id))

  defp member_of?(state, user_id) do
    user_id != nil and
      (player?(state, user_id) or Enum.any?(state.watchers, &(&1.id == user_id)))
  end

  def room_exists?(room_id) do
    case Registry.lookup(@registry, room_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @typedoc """
  Orders one drawer tab's canvas ops: `{op_epoch, op_seq}`, see
  `StrokeRules.op_tag/2`. The room keeps the last applied tag for the round
  and ignores an op with the same epoch and a seq that is not greater (a
  resend or a late duplicate). `nil` skips the check.
  """
  @type stroke_op :: {String.t(), pos_integer} | nil

  @doc """
  Appends a completed stroke drawn by `actor_id`, who must pass
  `authorize(state, actor_id, :draw)`. The stroke is
  `%{id, path, color, width}`, checked by `StrokeRules.check_append/2`; other
  keys are dropped.

  Idempotent: when the room already holds a stroke with that id, or `op` is
  stale (see `t:stroke_op/0`), nothing changes and it returns `:duplicate`.

  Returns `:ok`, `:duplicate`, `{:error, :not_drawer | :wrong_phase | :not_found}`,
  or `{:error, :invalid_stroke | :stroke_limit, strokes}` with the canvas as
  stored, so the drawer can resync.
  """
  @spec append_drawing(term, term, term, stroke_op) ::
          :ok
          | :duplicate
          | {:error, :not_drawer | :wrong_phase | :not_found}
          | {:error, :invalid_stroke | :stroke_limit, [StrokeRules.stroke()]}
  def append_drawing(room_id, actor_id, stroke, op \\ nil) do
    GenServer.call(via(room_id), {:append_drawing, actor_id, stroke, op})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Clears the canvas for the current drawer (`authorize/3` `:draw`). A stale
  `op` changes nothing and returns `:duplicate`.
  """
  @spec clear_drawing(term, term, stroke_op) ::
          :ok | :duplicate | {:error, :not_drawer | :wrong_phase | :not_found}
  def clear_drawing(room_id, actor_id, op \\ nil) do
    GenServer.call(via(room_id), {:clear_drawing, actor_id, op})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Removes the stroke with id `stroke_id` for the current drawer
  (`authorize/3` `:draw`) and returns the remaining strokes. An unknown id or
  a stale `op` changes nothing and returns `:duplicate`.
  """
  @spec undo_drawing(term, term, term, stroke_op) ::
          {:ok, [StrokeRules.stroke()]}
          | :duplicate
          | {:error, :not_drawer | :wrong_phase | :not_found}
  def undo_drawing(room_id, actor_id, stroke_id, op \\ nil) do
    GenServer.call(via(room_id), {:undo_drawing, actor_id, stroke_id, op})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Whether `user_id` is a player or a watcher of the room. `false` when the
  room is not running. Copies no state.
  """
  @spec member?(term, term) :: boolean
  def member?(room_id, user_id) do
    GenServer.call(via(room_id), {:member?, user_id})
  catch
    :exit, _ -> false
  end

  @doc """
  Whether `user_id` may draw right now (`authorize/3` `:draw`). `false` when
  the room is not running. Copies no state.
  """
  @spec drawing_allowed?(term, term) :: boolean
  def drawing_allowed?(room_id, user_id) do
    GenServer.call(via(room_id), {:drawing_allowed?, user_id})
  catch
    :exit, _ -> false
  end

  def list_active_rooms do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.reduce([], fn {room_id, _pid}, acc ->
      case get_state(room_id) do
        {:ok, state} -> [state | acc]
        _ -> acc
      end
    end)
  end

  # A dissolved room (`:ended` in the DB) is never started again: visiting its
  # URL must not resurrect a process nothing would stop. `{:stop, _}` (not
  # `:ignore`) so ensure_started/1 returns `{:error, :room_ended}`.
  @impl true
  def init(room_id) do
    case Games.get_room_by_id(room_id) do
      {:ok, %{status: :ended}} ->
        {:stop, :room_ended}

      {:ok, room} ->
        creator_name =
          case Ash.get(Scrawly.Accounts.User, room.creator_id) do
            {:ok, user} -> user.username || "Unknown"
            _ -> "Unknown"
          end

        state = %__MODULE__{
          room_id: room.id,
          name: room.name,
          code: room.code,
          status: room.status,
          creator_id: room.creator_id,
          max_players: room.max_players,
          players: Enum.map(room.players, &to_player_map/1),
          word_count: room.word_count || 1,
          word_source: room.word_source || :local,
          prompt: room.prompt,
          creator_name: creator_name,
          round_duration: room.round_duration || 60,
          round_multiplier: room.round_multiplier || 1,
          ai_tone: room.ai_tone || :fun,
          version: 0
        }

        notify_lobby()
        {:ok, resume_post_game(state)}

      {:error, _} ->
        {:stop, :room_not_found}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, to_public(state)}, state}
  end

  def handle_call({:get_view, viewer_id}, _from, state) do
    {:reply, {:ok, View.for_viewer(state, viewer_id)}, state}
  end

  def handle_call({:join, player}, _from, state) do
    already_in = Enum.any?(state.players, &(&1.id == player.id))

    cond do
      already_in ->
        {:reply, {:ok, to_public(state)}, state}

      length(state.players) >= state.max_players ->
        {:reply, {:error, :room_full}, state}

      state.status != :lobby ->
        {:reply, {:error, :not_in_lobby}, state}

      player.id != state.creator_id and not creator_present?(state) ->
        {:reply, {:error, :creator_not_present}, state}

      true ->
        new_state =
          %{state | players: state.players ++ [player]}
          |> add_sys_msg("#{player.username} joined the room")
          |> bump_version()
          |> notify_waiters()

        notify_lobby()
        {:reply, {:ok, to_public(new_state)}, new_state}
    end
  end

  def handle_call({:leave, player_id}, _from, state) do
    cond do
      authorize(state, player_id, :leave) != :ok ->
        {:reply, {:error, :not_member}, state}

      player_id == state.creator_id ->
        {:stop, :normal, {:ok, :dissolved}, end_room(state)}

      true ->
        player_name = get_player_name(state.players, player_id)

        new_state =
          %{state | players: Enum.reject(state.players, &(&1.id == player_id))}
          |> add_sys_msg("#{player_name} left the room")
          |> bump_version()
          |> notify_waiters()

        notify_lobby()
        {:reply, {:ok, to_public(new_state)}, new_state}
    end
  end

  def handle_call({:join_watcher, watcher}, _from, state) do
    already_watching = Enum.any?(state.watchers, &(&1.id == watcher.id))

    cond do
      already_watching ->
        {:reply, {:ok, to_public(state)}, state}

      length(state.watchers) >= @max_watchers ->
        {:reply, {:error, :room_full}, state}

      true ->
        new_state =
          %{state | watchers: state.watchers ++ [watcher]}
          |> add_sys_msg("#{watcher.username} is now watching")
          |> bump_version()
          |> notify_waiters()

        {:reply, {:ok, to_public(new_state)}, new_state}
    end
  end

  def handle_call({:leave_watcher, watcher_id}, _from, state) do
    case Enum.find(state.watchers, &(&1.id == watcher_id)) do
      nil ->
        {:reply, {:ok, to_public(state)}, state}

      watcher ->
        new_state =
          %{state | watchers: Enum.reject(state.watchers, &(&1.id == watcher_id))}
          |> add_sys_msg("#{watcher.username} stopped watching")
          |> bump_version()
          |> notify_waiters()

        {:reply, {:ok, to_public(new_state)}, new_state}
    end
  end

  def handle_call({:update_player_score, player_id, points}, _from, state) do
    updated_players =
      Enum.map(state.players, fn p ->
        if p.id == player_id, do: %{p | score: (p.score || 0) + points}, else: p
      end)

    new_state =
      %{state | players: updated_players}
      |> bump_version()
      |> notify_waiters()

    {:reply, {:ok, to_public(new_state)}, new_state}
  end

  def handle_call({:start_game, actor_id, opts}, _from, state) do
    total_rounds = length(state.players) * (state.round_multiplier || 1)

    with :ok <- authorize(state, actor_id, :start_game),
         {:ok, game} <- persist_game_start(state.room_id, total_rounds) do
      new_state = begin_game(state, game.id, total_rounds, opts)
      notify_lobby()
      {:reply, {:ok, to_public(new_state)}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:choose_word, player_id, word}, _from, state) do
    cond do
      state.phase != :choosing ->
        {:reply, {:error, :not_choosing}, state}

      player_id != state.current_drawer_id ->
        {:reply, {:error, :not_drawer}, state}

      word not in state.word_choices ->
        {:reply, {:error, :invalid_word}, state}

      true ->
        case GameFlow.commit_word_choice(state, word) do
          {:ok, new_state} ->
            new_state =
              new_state
              |> bump_version()
              |> notify_waiters()

            {:reply, {:ok, to_public(new_state)}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:submit_message, user_id, text}, _from, state) do
    now = System.monotonic_time(:millisecond)

    with {:ok, text} <- clean_message(text),
         {:ok, sender} <- find_sender(state, user_id),
         {:ok, recent} <- check_chat_rate(state, user_id, now),
         :ok <- check_drawer_can_chat(state, user_id) do
      state
      |> put_chat_rate(user_id, [now | recent], now)
      |> deliver_message(sender, text)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:system_message, text}, _from, state) do
    new_state =
      state
      |> add_sys_msg(text)
      |> bump_version()
      |> notify_waiters(false)

    {:reply, :ok, new_state}
  end

  def handle_call(:end_game, _from, state) do
    if state.game_id do
      Games.save_game_results(state.game_id, state.room_id, state.players, state.round_results)
      Games.set_room_post_game(state.room_id)
      Phoenix.PubSub.unsubscribe(Scrawly.PubSub, "game:#{state.game_id}")
    end

    game_entry = GameFlow.build_past_game_entry(state)

    new_state =
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
          past_games: [game_entry | state.past_games],
          post_game_deadline: schedule_return_to_lobby()
      }
      |> add_sys_msg("Game over! Final scores are in.")
      |> bump_version()
      |> notify_waiters()

    notify_lobby()

    {:reply, {:ok, to_public(new_state)}, new_state}
  end

  def handle_call({:dissolve_room, actor_id}, _from, state) do
    case authorize(state, actor_id, :dissolve) do
      :ok -> {:stop, :normal, :ok, end_room(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:append_drawing, actor_id, stroke, op}, _from, state) do
    with :ok <- authorize(state, actor_id, :draw),
         :ok <- fresh_stroke_op(state, op),
         :ok <- new_stroke_id(state, stroke),
         {:ok, stroke} <- StrokeRules.check_append(state.drawing_strokes, stroke) do
      {:reply, :ok, state |> put_stroke_op(op) |> put_strokes(state.drawing_strokes ++ [stroke])}
    else
      :duplicate ->
        {:reply, :duplicate, state}

      {:error, reason} when reason in [:invalid_stroke, :stroke_limit] ->
        {:reply, {:error, reason, state.drawing_strokes}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:clear_drawing, actor_id, op}, _from, state) do
    with :ok <- authorize(state, actor_id, :draw),
         :ok <- fresh_stroke_op(state, op) do
      {:reply, :ok, state |> put_stroke_op(op) |> put_strokes([])}
    else
      :duplicate -> {:reply, :duplicate, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:undo_drawing, actor_id, stroke_id, op}, _from, state) do
    with :ok <- authorize(state, actor_id, :draw),
         :ok <- fresh_stroke_op(state, op),
         {:ok, remaining} <- drop_stroke(state.drawing_strokes, stroke_id) do
      {:reply, {:ok, remaining}, state |> put_stroke_op(op) |> put_strokes(remaining)}
    else
      :duplicate -> {:reply, :duplicate, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:member?, user_id}, _from, state) do
    {:reply, member_of?(state, user_id), state}
  end

  def handle_call({:drawing_allowed?, user_id}, _from, state) do
    {:reply, authorize(state, user_id, :draw) == :ok, state}
  end

  # The commit delta already carries the round: nothing to send.
  @impl true
  def handle_info({:timer_started, _info}, state), do: {:noreply, state}

  # Time-up from RoundTimer, only for this game's current round while it is
  # still being drawn: an expiry already queued when everyone guessed (or one
  # for an earlier round) must not score the drawer, capture the round or
  # schedule an advance a second time.
  def handle_info({:round_ended, %{reason: :time_up} = info}, state) do
    if state.game_id != nil and Map.get(info, :game_id) == state.game_id and
         Map.get(info, :round) == state.current_round and state.phase == :drawing,
       do: {:noreply, time_up(state)},
       else: {:noreply, state}
  end

  # A hint stage is due. Only for this game's current round while drawing;
  # broadcasts only when the mask changes (a short word's later batch can be
  # empty).
  def handle_info({:hint_reveal, game_id, round, stage}, state) do
    if state.game_id != nil and game_id == state.game_id and round == state.current_round and
         state.phase == :drawing and stage > state.hint_stage do
      new_state = %{state | hint_stage: stage}

      if WordHints.hint_for_stage(state.current_word, stage) ==
           WordHints.hint_for_stage(state.current_word, state.hint_stage),
         do: {:noreply, new_state},
         else: {:noreply, new_state |> bump_version() |> notify_waiters()}
    else
      {:noreply, state}
    end
  end

  def handle_info(:auto_advance_round, state) do
    if state.game_id && not state.round_active && state.phase != :choosing do
      if state.current_round >= state.total_rounds do
        {:noreply, auto_end_game(state)}
      else
        {:noreply, auto_next_round(state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:word_choice_timeout, game_id, round}, state) do
    cond do
      state.game_id != game_id ->
        {:noreply, state}

      state.current_round != round ->
        {:noreply, state}

      state.phase != :choosing ->
        {:noreply, state}

      state.word_choices == [] ->
        {:noreply, state}

      true ->
        chosen = Enum.random(state.word_choices)

        case GameFlow.commit_word_choice(state, chosen) do
          {:ok, new_state} ->
            new_state =
              new_state
              |> add_sys_msg("Word auto-selected for the drawer")
              |> bump_version()
              |> notify_waiters()

            {:noreply, new_state}

          {:error, _} ->
            {:noreply, state}
        end
    end
  end

  def handle_info(:return_to_lobby, state) do
    if state.status == :post_game do
      Games.return_room_to_lobby(state.room_id)

      new_state =
        %{state | status: :lobby, players: [], post_game_deadline: nil}
        |> add_sys_msg("Room is back in the lobby. Start a new game!")
        |> bump_version()
        |> notify_waiters()

      notify_lobby()
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:stop_self, state) do
    notify_lobby()
    {:stop, :normal, state}
  end

  def handle_info({:refill_ai_words, _room_id, word_count, total_rounds, ai_tone}, state) do
    if state.prompt && state.prompt != "" && state.game_id do
      tone_str = to_string(ai_tone || :fun)
      num_words = min(max(total_rounds * 3, 9), 60)

      case Games.generate_ai_words(state.prompt, word_count, %{
             num_words: num_words,
             tone: tone_str
           }) do
        {:ok, words} when is_list(words) and words != [] ->
          new_words = Enum.uniq(words ++ state.ai_words)
          {:noreply, %{state | ai_words: new_words}}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:timer_stopped, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Chat and guesses (submit_message/3) ───────────────────────────────────

  defp clean_message(text) when is_binary(text) do
    if String.valid?(text) do
      case text |> String.trim() |> String.slice(0, @max_message_length) do
        "" -> {:error, :empty}
        text -> {:ok, text}
      end
    else
      {:error, :empty}
    end
  end

  defp clean_message(_text), do: {:error, :empty}

  # Players first: a player who also watches keeps their player identity.
  defp find_sender(_state, nil), do: {:error, :not_in_room}

  defp find_sender(state, user_id) do
    case Enum.find(state.players, &(&1.id == user_id)) ||
           Enum.find(state.watchers, &(&1.id == user_id)) do
      nil -> {:error, :not_in_room}
      member -> {:ok, member}
    end
  end

  defp check_chat_rate(state, user_id, now) do
    recent =
      state.chat_rate_limits
      |> Map.get(user_id, [])
      |> Enum.filter(&(now - &1 < @chat_window_ms))

    if length(recent) >= @chat_max_messages, do: {:error, :rate_limited}, else: {:ok, recent}
  end

  # Also drops senders whose timestamps have all expired, so the map stays small.
  defp put_chat_rate(state, user_id, stamps, now) do
    limits =
      state.chat_rate_limits
      |> Map.put(user_id, stamps)
      |> Map.filter(fn {_id, ts} -> Enum.any?(ts, &(now - &1 < @chat_window_ms)) end)

    %{state | chat_rate_limits: limits}
  end

  defp check_drawer_can_chat(state, user_id) do
    if user_id == state.current_drawer_id and state.phase in [:choosing, :drawing],
      do: {:error, :drawer_cannot_chat},
      else: :ok
  end

  # The text of a correct or suppressed guess is never stored or broadcast.
  defp deliver_message(state, sender, text) do
    cond do
      not (state.phase == :drawing and Guess.matches?(text, state.current_word)) ->
        {:reply, {:ok, :chat}, append_chat(state, sender, text)}

      can_score?(state, sender.id) ->
        {new_state, points} = award_guess(state, sender.id)
        {:reply, {:ok, {:correct, points}}, new_state}

      true ->
        {:reply, {:ok, :suppressed}, state}
    end
  end

  defp can_score?(state, user_id) do
    player?(state, user_id) and user_id != state.current_drawer_id and
      user_id not in state.correct_guessers
  end

  defp append_chat(state, sender, text) do
    state
    |> GameFlow.push_chat(%{
      player_id: sender.id,
      player_name: Map.get(sender, :username) || "Unknown",
      message: text,
      type: :chat
    })
    |> bump_version()
    |> notify_waiters(false)
  end

  # Scores a correct guess, posts the :correct_guess line, and ends the round
  # early (scoring the drawer) once every non-drawer player has guessed.
  defp award_guess(state, player_id) do
    order = length(state.correct_guessers) + 1
    guess_pts = Scoring.guesser_points(time_left(state), state.round_duration, order: order)
    new_guessers = [player_id | state.correct_guessers]
    new_round_points = state.round_guesser_points ++ [guess_pts]

    guesser_ids =
      state.players
      |> Enum.reject(&(&1.id == state.current_drawer_id))
      |> Enum.map(& &1.id)

    all_guessed = length(guesser_ids) > 0 and Enum.all?(guesser_ids, &(&1 in new_guessers))

    updated_players =
      Enum.map(state.players, fn p ->
        if p.id == player_id, do: %{p | score: (p.score || 0) + guess_pts}, else: p
      end)

    player_name = get_player_name(state.players, player_id)

    intermediate =
      %{
        state
        | players: updated_players,
          correct_guessers: new_guessers,
          round_guesser_points: new_round_points
      }
      |> add_sys_msg("#{player_name} guessed the word! (+#{guess_pts} points)", :correct_guess)

    new_state =
      if all_guessed do
        Games.stop_round_timer(state.game_id)
        Process.send_after(self(), :auto_advance_round, 3_000)

        drawer_pts = Scoring.drawer_round_points(new_round_points)
        drawer_name = get_player_name(state.players, state.current_drawer_id)

        updated_players_with_drawer =
          Enum.map(intermediate.players, fn p ->
            if p.id == state.current_drawer_id,
              do: %{p | score: (p.score || 0) + drawer_pts},
              else: p
          end)

        %{
          intermediate
          | players: updated_players_with_drawer,
            round_active: false,
            phase: :round_end,
            round_deadline: nil
        }
        |> capture_round_result(drawer_pts)
        |> add_sys_msg("Everyone guessed! #{drawer_name} earns #{drawer_pts} pts!")
      else
        intermediate
      end
      |> bump_version()
      |> notify_waiters()

    {new_state, guess_pts}
  end

  # The round timed out: score the drawer, reveal the word, advance in 3 s.
  defp time_up(state) do
    correct_count = length(state.correct_guessers)
    drawer_pts = Scoring.drawer_round_points(state.round_guesser_points)
    drawer_name = get_player_name(state.players, state.current_drawer_id)

    updated_players =
      Enum.map(state.players, fn p ->
        if p.id == state.current_drawer_id,
          do: %{p | score: (p.score || 0) + drawer_pts},
          else: p
      end)

    msg =
      if correct_count > 0 do
        "Time's up! The word was: #{state.current_word}. #{drawer_name} earned #{drawer_pts} pts (#{correct_count} guessed)"
      else
        "Time's up! The word was: #{state.current_word}. Nobody guessed."
      end

    new_state =
      %{
        state
        | players: updated_players,
          round_deadline: nil,
          round_active: false,
          phase: :round_end
      }
      |> capture_round_result(drawer_pts)
      |> add_sys_msg(msg)
      |> bump_version()
      |> notify_waiters()

    Process.send_after(self(), :auto_advance_round, 3_000)
    new_state
  end

  defp end_room(state) do
    if state.game_id, do: Phoenix.PubSub.unsubscribe(Scrawly.PubSub, "game:#{state.game_id}")

    new_state =
      %{state | players: [], status: :ended}
      |> bump_version()
      |> notify_waiters()

    notify_lobby()
    new_state
  end

  # Marks the room as playing and creates its Game row. If the Game row can't be
  # created, the room is put back in the lobby so no half-started game remains.
  defp persist_game_start(room_id, total_rounds) do
    with {:ok, _room} <- Games.start_game(room_id) do
      case Games.create_game(room_id, total_rounds) do
        {:ok, game} ->
          {:ok, game}

        {:error, _} ->
          Games.return_room_to_lobby(room_id)
          {:error, :start_failed}
      end
    else
      {:error, _} -> {:error, :start_failed}
    end
  end

  defp begin_game(state, game_id, total_rounds, opts) do
    Phoenix.PubSub.subscribe(Scrawly.PubSub, "game:#{game_id}")
    drawer_id = hd(state.players).id
    drawer_name = get_player_name(state.players, drawer_id)
    reset_players = Enum.map(state.players, fn p -> %{p | score: 0} end)

    %{
      state
      | players: reset_players,
        status: :playing,
        last_game_id: nil,
        game_id: game_id,
        current_round: 1,
        total_rounds: total_rounds,
        current_drawer_id: drawer_id,
        current_word: nil,
        round_deadline: nil,
        hint_stage: 0,
        round_active: false,
        correct_guessers: [],
        drawing_strokes: [],
        stroke_op: nil,
        chat_messages: [],
        round_results: [],
        used_words: [],
        ai_words: Map.get(opts, :ai_words, state.ai_words),
        round_guesser_points: [],
        round_start_scores:
          Enum.reduce(reset_players, %{}, fn p, acc -> Map.put(acc, p.id, 0) end)
    }
    |> add_sys_msg("Game started! #{drawer_name} is choosing a word \u2026")
    |> GameFlow.enter_word_choice(
      Map.get(opts, :word_choices) || [],
      &schedule_word_choice_timeout/2
    )
    |> bump_version()
    |> notify_waiters()
  end

  defp auto_next_round(state) do
    GameFlow.start_word_choice(
      state,
      &bump_version/1,
      &notify_waiters/1,
      &schedule_word_choice_timeout/2
    )
  end

  # GameFlow.auto_end_game/3 keeps this field (it updates with %{state | ...}),
  # so the deadline is set before its :room_delta goes out and a page reacting
  # to it reads the time left from get_state/1.
  defp auto_end_game(state) do
    notify_lobby()
    state = %{state | post_game_deadline: schedule_return_to_lobby()}
    GameFlow.auto_end_game(state, &bump_version/1, &notify_waiters/1)
  end

  # Schedules :return_to_lobby and returns the matching monotonic deadline.
  defp schedule_return_to_lobby do
    Process.send_after(self(), :return_to_lobby, @post_game_ms)
    System.monotonic_time(:millisecond) + @post_game_ms
  end

  # A room restarted while the DB says :post_game (e.g. after a crash; the
  # child is :temporary) gets a fresh full window, otherwise nothing would
  # ever return it to the lobby.
  defp resume_post_game(%{status: :post_game} = state),
    do: %{state | post_game_deadline: schedule_return_to_lobby()}

  defp resume_post_game(state), do: state

  defp schedule_word_choice_timeout(game_id, round) do
    Process.send_after(
      self(),
      {:word_choice_timeout, game_id, round},
      GameFlow.choice_duration_ms()
    )
  end

  defp fresh_stroke_op(%{stroke_op: {epoch, last}}, {epoch, seq}) when seq <= last,
    do: :duplicate

  defp fresh_stroke_op(_state, _op), do: :ok

  defp put_stroke_op(state, nil), do: state
  defp put_stroke_op(state, op), do: %{state | stroke_op: op}

  defp new_stroke_id(state, %{id: id}) do
    if Enum.any?(state.drawing_strokes, &(&1.id == id)), do: :duplicate, else: :ok
  end

  defp new_stroke_id(_state, _stroke), do: :ok

  defp drop_stroke(strokes, stroke_id) do
    case Enum.split_with(strokes, &(&1.id == stroke_id)) do
      {[], _strokes} -> :duplicate
      {_dropped, remaining} -> {:ok, remaining}
    end
  end

  # Stroke changes are fanned out by the stroke commands, not by :room_delta.
  defp put_strokes(state, strokes) do
    %{state | drawing_strokes: strokes}
    |> bump_version()
    |> notify_waiters(false)
  end

  defp via(room_id), do: {:via, Registry, {@registry, room_id}}
  defp creator_present?(state), do: Enum.any?(state.players, &(&1.id == state.creator_id))
  defp bump_version(state), do: %{state | version: state.version + 1}
  defp notify_lobby, do: Phoenix.PubSub.broadcast(Scrawly.PubSub, "lobby:rooms", :rooms_updated)

  defp notify_waiters(state, broadcast \\ true) do
    if broadcast do
      Hologram.Realtime.broadcast_action({:room, state.room_id}, :room_delta, public_delta(state))
    end

    state
  end

  defp public_delta(state), do: View.delta(state)

  defp to_public(state), do: View.public(state)

  defp to_player_map(user) do
    %{
      id: user.id,
      username: user.username,
      score: user.score || 0,
      avatar_id: Map.get(user, :avatar_id) || "a-mushroom",
      avatar_color: Map.get(user, :avatar_color) || "3"
    }
  end

  defp capture_round_result(state, drawer_points),
    do: GameFlow.capture_round_result(state, drawer_points)

  defp get_player_name(players, player_id), do: GameFlow.get_player_name(players, player_id)
  defp add_sys_msg(state, text, type \\ :system), do: GameFlow.add_sys_msg(state, text, type)
end
