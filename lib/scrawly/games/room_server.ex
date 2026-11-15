defmodule Scrawly.Games.RoomServer do
  @moduledoc """
  GenServer representing a game room. Single source of truth for room membership,
  game state, chat messages, and drawing data. Every change is pushed to the
  subscribed game pages through Hologram Realtime, sequenced
  (`RoomServer.Broadcasts`): `:room_delta`, `:chat_appended`,
  `:stroke_completed`, `:drawing_cleared` and `:drawing_undone` on
  `{:room, room_id}`, and the drawer's word choices and word on their own
  `{:room_player, room_id, user_id}` channel, after the public delta. The
  home pages' room list gets the room's lobby summary (or its removal) on
  `:lobby` whenever its lobby status or players change.

  Rounds run against monotonic deadlines (`round_deadline`, `choice_deadline`):
  the room broadcasts the remaining ms in its deltas and clients count down
  locally, so nothing is pushed while a countdown runs. The room times its
  turns itself (`GameFlow`: the round's `{:round_ended, ...}` expiry, the
  `{:hint_reveal, ...}` stages, the choice timeout and the advance after a
  round, all `Process.send_after/3` to itself and cancelled when the turn or
  the game ends). Auto-advances rounds when time is up, all players guessed
  or the drawer left; a transition that can't happen ends the game instead
  of leaving the room stuck.

  The drawer order is the room's `turn_queue`, built when the game starts
  (`total_rounds/2` turns, every player the same number of times); a player
  who leaves mid-game loses their remaining turns, the turn ends at once if
  they were drawing or choosing, and the game ends when fewer than 2 players
  remain.

  Presence: Hologram has no disconnect hook, so every few seconds
  (`:presence_sweep`) the room asks `ScrawlyWeb.OnlineTracker`, which every
  open tab's layout heartbeat feeds, which of its watchers (in any phase)
  and of its players (only while the room is in its lobby) still have a
  live tab, keyed by `ScrawlyWeb.Auth.actor_key/1` like the tracker. A
  watcher missing from the tracker for `presence_grace_ms/0` (a lobby player:
  `player_presence_grace_ms/0`) is removed (a player also loses their DB
  membership; the creator dissolves the room, as their leaving does). Mid-game players are never removed this way: a drawer who
  vanished keeps the round running to its deadline.
  """
  use GenServer

  require Logger

  alias Scrawly.{Accounts, Games}

  alias Scrawly.Games.{
    AiWords,
    AnswerKind,
    Guess,
    Scoring,
    StrokeRules,
    WordHints,
    RoomServer.Broadcasts,
    RoomServer.GameFlow,
    RoomServer.View
  }

  @registry Scrawly.RoomRegistry
  @supervisor Scrawly.RoomSupervisor
  @max_watchers 50
  @max_message_length 240
  # One character can be megabytes ("a" and thousands of combining marks),
  # so lines are cut by bytes too (Scrawly.Text).
  @max_message_bytes 1_000
  @chat_max_messages 3
  @chat_window_ms 5_000
  # How long a finished game's score page shows before the room returns to the
  # lobby (`:return_to_lobby`).
  @post_game_ms 30_000
  # How long a finished round shows its word and its summary (View's
  # round_summary) before the next one starts.
  @round_end_ms 5_000
  # A close guess is echoed to its sender cut to this many characters.
  @close_echo_chars 40
  @no_word_text "No word could be picked, so the game ended."
  # Watch joins and leaves an actor may make per window, together: an over
  # the limit join is refused, a leave never is (and leaves can't outnumber
  # joins).
  @watch_max_events 8
  @watch_window_ms 60_000
  # How often the room checks its members against OnlineTracker, and how
  # long a key may be missing there before its member is removed. The
  # tracker drops a key 45 s after its last heartbeat (every 20 s per tab,
  # about once a minute in a long-hidden, throttled one), so a closed tab
  # goes 105-135 s after its last heartbeat. Both can be overridden with
  # `config :scrawly, Scrawly.Games.RoomServer, presence_sweep_ms:,
  # presence_grace_ms:` (read at init; `presence_sweep_ms: false` turns the
  # sweep off, as the test config does).
  @presence_sweep_ms 15_000
  # Watchers go after a minute without a tab. Lobby players (the creator
  # included, whose absence dissolves the room) get longer, so a phone that
  # backgrounds the tab for a couple of minutes doesn't lose its room.
  @presence_grace_ms 60_000
  @player_presence_grace_ms 300_000

  defstruct [
    :room_id,
    :name,
    :code,
    :status,
    :creator_id,
    :max_players,
    players: [],
    watchers: [],
    # Seq of the last {:room} broadcast (Broadcasts.publish/3). Seeded from
    # the wall clock in µs in init/1, so a restarted room (the child is
    # :temporary) keeps counting up from above anything its previous process
    # sent unless that one averaged more than a broadcast per µs.
    seq: 0,
    # Words, phrases or both (AnswerKind): every pick of word choices
    # follows it, the AI's included.
    answer_kind: AnswerKind.default(),
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
    past_games: [],
    # Drawer ids of the game's remaining turns, in order (the current
    # drawer's turn excluded). Built by begin_game; a leaver's turns are
    # removed.
    turn_queue: [],
    # Process.send_after refs of the current turn (GameFlow.track_timer/2).
    turn_timers: [],
    # `{task_ref, game_id}` while an AI word refill runs in a task.
    ai_refill: nil,
    # Sliding-window rate limits: actor key => recent monotonic ms stamps
    # (newest first) of watch joins/leaves, and of the drawer's stroke ops.
    watch_rate_limits: %{},
    stroke_rate_limits: %{},
    # Member id => monotonic ms since which OnlineTracker hasn't had their
    # key (sweep_presence/2), only for members it currently misses.
    absent_since: %{},
    presence_sweep_ms: @presence_sweep_ms,
    presence_grace_ms: @presence_grace_ms,
    player_presence_grace_ms: @player_presence_grace_ms
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

  @doc "How long, in ms, the `:round_end` pause lasts before the next turn starts."
  @spec round_end_ms() :: pos_integer
  def round_end_ms, do: @round_end_ms

  @doc """
  How long, in ms, a member's key may be missing from
  `ScrawlyWeb.OnlineTracker` before the presence sweep removes them (the
  default; see the moduledoc).
  """
  @spec presence_grace_ms() :: pos_integer
  def presence_grace_ms, do: @presence_grace_ms

  @doc """
  How long a LOBBY player (the creator included) may be missing from
  `ScrawlyWeb.OnlineTracker` before the presence sweep removes them. Longer
  than the watchers' `presence_grace_ms/0` so a briefly backgrounded phone
  keeps its room.
  """
  @spec player_presence_grace_ms() :: pos_integer
  def player_presence_grace_ms, do: @player_presence_grace_ms

  @doc "`{events, window_ms}`: watch joins and leaves an actor may make in a room."
  @spec watch_rate_limit() :: {pos_integer, pos_integer}
  def watch_rate_limit, do: {@watch_max_events, @watch_window_ms}

  def start_link(room_id), do: GenServer.start_link(__MODULE__, room_id, name: via(room_id))

  def child_spec(room_id) do
    %{id: {__MODULE__, room_id}, start: {__MODULE__, :start_link, [room_id]}, restart: :temporary}
  end

  @doc """
  The number of rounds of a game with `player_count` players and the room's
  rounds-per-player `multiplier`: whole rotations (every player draws the
  same number of times), as many as the multiplier asks for but never more
  than `Scrawly.Games.Game.max_total_rounds/0` rounds in total. So every
  setting the home page offers can start (12 players at 5x get 2 turns
  each, 24 rounds).
  """
  @spec total_rounds(non_neg_integer, pos_integer) :: non_neg_integer
  def total_rounds(player_count, _multiplier) when player_count < 1, do: 0

  def total_rounds(player_count, multiplier) do
    cap = Games.Game.max_total_rounds()
    turns = multiplier |> max(1) |> min(max(1, div(cap, player_count)))
    min(player_count * turns, cap)
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

  @doc """
  The current drawer's private slice (`View.private_slice/1`) when
  `viewer_id` is the drawer, `{:error, :not_drawer}` otherwise.
  """
  @spec get_private_slice(term, term) :: {:ok, map} | {:error, :not_drawer | :not_found}
  def get_private_slice(room_id, viewer_id) do
    GenServer.call(via(room_id), {:get_private_slice, viewer_id})
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

  `opts` may carry `:word_choices` (first round's choices, picked for the
  room's `answer_kind` with `GameFlow.pick_word_choices/4`) and `:ai_words`
  (the remaining AI pool); without choices the room picks them itself.
  Returns `{:ok, public_state}` or `{:error, reason}`.
  """
  def start_game(room_id, actor_id, opts \\ %{}) do
    GenServer.call(via(room_id), {:start_game, actor_id, Map.new(opts)})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Submits a chat line typed by `user_id`. Guesses are checked here, in the room
  process, so scoring is atomic and guess order is deterministic.

  The text is trimmed and capped at #{@max_message_length} characters and
  #{@max_message_bytes} bytes (`Scrawly.Text.clean/3`; a line whose first
  character alone is bigger is `:empty`). The sender must be a player or a
  watcher; the displayed name is always the stored
  username. Every sender is limited to #{@chat_max_messages} messages per
  #{@chat_window_ms} ms, guesses included.

  Replies:

    * `{:ok, {:correct, points}}` - a non-drawer player who hasn't guessed yet
      typed the word itself (`Guess.matches?/2`: case, accents, spacing and
      punctuation ignored, so "Ice-Cream!" and "icecream" score for "ice
      cream") while `:drawing`. The text is not stored; a `:correct_guess`
      line is posted instead, and the word goes to that player alone, on
      their own channel (`Broadcasts.push_private_slice/2`).
    * `{:ok, :suppressed}` - any other line that contains the word
      (`Guess.contains_word?/2`: the same variants, as a run of whole words)
      while `:drawing`: a line like "is it icecream?" or "lol it is ZZYZX",
      or the word from a player who already guessed or from a watcher.
      Nothing is stored or broadcast; only the sender is told.
    * `{:ok, {:close, text}}` - a line one edit away from the word
      (`Guess.close?/2`: an answer of 5 or more letters, compared on keys)
      while `:drawing`, e.g. "popcorm" for "popcorn". Nothing is stored,
      broadcast or scored; `text` is the sender's own line (cut to
      #{@close_echo_chars} characters) for their private "is close" line.
    * `{:ok, :chat}` - anything else, stored and broadcast as `:chat`.
    * `{:error, :empty | :not_in_room | :rate_limited | :drawer_cannot_chat |
      :not_found}` - nothing changes.
  """
  @spec submit_message(term, term, term) ::
          {:ok, {:correct, pos_integer} | {:close, String.t()} | :suppressed | :chat}
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
    * `:draw` - the actor is the current drawer and still one of the
      players (`:not_drawer`, see `View.drawer?/2`) and the room is in
      `:drawing` (`:wrong_phase`). Covers strokes, clear and undo.
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
      not View.drawer?(state, actor_id) -> {:error, :not_drawer}
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

  Returns `:ok`, `:duplicate`, `{:error, :not_drawer | :wrong_phase |
  :rate_limited | :not_found}`, or `{:error, :invalid_stroke | :stroke_limit,
  strokes}` with the canvas as stored, so the drawer can resync. A stored
  stroke is published to the whole room as `:stroke_completed` (`%{stroke_id,
  path, color, width, seq}`).

  The drawer's stroke ops (appends, clears and undos together, duplicates
  included) are limited to `StrokeRules.op_rate_limit/0`; one over the
  limit changes nothing, doesn't count, and gets `{:error, :rate_limited}`.
  """
  @spec append_drawing(term, term, term, stroke_op) ::
          :ok
          | :duplicate
          | {:error, :not_drawer | :wrong_phase | :rate_limited | :not_found}
          | {:error, :invalid_stroke | :stroke_limit, [StrokeRules.stroke()]}
  def append_drawing(room_id, actor_id, stroke, op \\ nil) do
    GenServer.call(via(room_id), {:append_drawing, actor_id, stroke, op})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Clears the canvas for the current drawer (`authorize/3` `:draw`) and
  publishes `:drawing_cleared` (`%{op_epoch}`: the epoch of `op`, or nil, so
  the drawer's other tabs can tell it from their own). A stale `op` changes
  nothing and returns `:duplicate`.
  """
  @spec clear_drawing(term, term, stroke_op) ::
          :ok | :duplicate | {:error, :not_drawer | :wrong_phase | :rate_limited | :not_found}
  def clear_drawing(room_id, actor_id, op \\ nil) do
    GenServer.call(via(room_id), {:clear_drawing, actor_id, op})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Removes the stroke with id `stroke_id` for the current drawer
  (`authorize/3` `:draw`) and publishes only that id as `:drawing_undone`
  (`%{stroke_id, seq}`): pages remove it from the canvas they hold, so the
  canvas is never re-sent. An unknown id or a stale `op` changes nothing
  and returns `:duplicate`.
  """
  @spec undo_drawing(term, term, term, stroke_op) ::
          :ok
          | :duplicate
          | {:error, :not_drawer | :wrong_phase | :rate_limited | :not_found}
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

  @doc """
  The home page's room list: `lobby_summary/1` of every running room that is
  listed (`Broadcasts.listed?/1`: in the lobby, creator present). Each room
  keeps its own summary as its Registry value (updated with every lobby
  change, see `notify_lobby/1`), so this reads the Registry and calls no
  room: a busy room can't slow the home page down, and a stopped room's
  entry is gone with its process.
  """
  @spec list_lobby_rooms() :: [map]
  def list_lobby_rooms do
    Registry.select(@registry, [{{:_, :_, :"$1"}, [{:is_map, :"$1"}], [:"$1"]}])
  end

  @doc "What the home page's room list shows of a room (`View.lobby_summary/1`)."
  @spec lobby_summary(struct) :: map
  defdelegate lobby_summary(state), to: View

  # A dissolved room (`:ended` in the DB) is never started again: visiting its
  # URL must not resurrect a process nothing would stop. `{:stop, _}` (not
  # `:ignore`) so ensure_started/1 returns `{:error, :room_ended}`. A room
  # whose DB status is still :playing lost its game with its previous process
  # (crash, deploy): it comes back in the lobby (recover_interrupted_game/1).
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
          answer_kind: AnswerKind.parse(room.answer_kind),
          word_source: room.word_source || :local,
          prompt: room.prompt,
          creator_name: creator_name,
          round_duration: room.round_duration || 60,
          round_multiplier: room.round_multiplier || 1,
          ai_tone: room.ai_tone || :fun,
          seq: System.system_time(:microsecond)
        }

        state = put_presence_config(state)
        schedule_presence_sweep(state)

        {:ok, state |> recover_interrupted_game() |> resume_post_game() |> notify_lobby()}

      {:error, _} ->
        {:stop, :room_not_found}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, to_public(state)}, state}
  end

  def handle_call(:lobby_summary, _from, state) do
    {:reply, if(Broadcasts.listed?(state), do: View.lobby_summary(state)), state}
  end

  def handle_call({:get_view, viewer_id}, _from, state) do
    {:reply, {:ok, View.for_viewer(state, viewer_id)}, state}
  end

  def handle_call({:get_private_slice, viewer_id}, _from, state) do
    if View.drawer?(state, viewer_id),
      do: {:reply, {:ok, View.private_slice(state)}, state},
      else: {:reply, {:error, :not_drawer}, state}
  end

  def handle_call({:join, player}, _from, state) do
    player = cap_name(player)
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
          |> notify_waiters()
          |> notify_lobby()

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
        new_state = player_left(state, player_id)
        {:reply, {:ok, to_public(new_state)}, new_state}
    end
  end

  # Watching posts no chat line (the room's watcher list shows who
  # watches), so joins and leaves can't flood the chat; they are
  # rate-limited per actor (watch_rate_limit/0).
  def handle_call({:join_watcher, watcher}, _from, state) do
    watcher = cap_name(watcher)
    already_watching = Enum.any?(state.watchers, &(&1.id == watcher.id))
    now = System.monotonic_time(:millisecond)

    cond do
      already_watching ->
        {:reply, {:ok, to_public(state)}, state}

      length(state.watchers) >= @max_watchers ->
        {:reply, {:error, :room_full}, state}

      true ->
        case take_slot(state, :watch_rate_limits, watcher.id, now, watch_rate_limit()) do
          {:ok, state} ->
            new_state = notify_waiters(%{state | watchers: state.watchers ++ [watcher]})
            {:reply, {:ok, to_public(new_state)}, new_state}

          :rate_limited ->
            {:reply, {:error, :rate_limited}, state}
        end
    end
  end

  def handle_call({:leave_watcher, watcher_id}, _from, state) do
    if Enum.any?(state.watchers, &(&1.id == watcher_id)) do
      now = System.monotonic_time(:millisecond)

      new_state =
        %{state | watchers: Enum.reject(state.watchers, &(&1.id == watcher_id))}
        |> record_slot(:watch_rate_limits, watcher_id, now, @watch_window_ms)
        |> notify_waiters()

      {:reply, {:ok, to_public(new_state)}, new_state}
    else
      {:reply, {:ok, to_public(state)}, state}
    end
  end

  def handle_call({:update_player_score, player_id, points}, _from, state) do
    updated_players =
      Enum.map(state.players, fn p ->
        if p.id == player_id, do: %{p | score: (p.score || 0) + points}, else: p
      end)

    new_state =
      %{state | players: updated_players}
      |> notify_waiters()

    {:reply, {:ok, to_public(new_state)}, new_state}
  end

  def handle_call({:start_game, actor_id, opts}, _from, state) do
    total_rounds = total_rounds(length(state.players), state.round_multiplier || 1)

    with :ok <- authorize(state, actor_id, :start_game),
         {:ok, game} <- persist_game_start(state.room_id, total_rounds) do
      new_state = state |> begin_game(game.id, total_rounds, opts) |> notify_lobby()
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
              |> notify_waiters()
              |> Broadcasts.push_private_slice()

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
    {:reply, :ok, add_sys_msg(state, text)}
  end

  # Ends the game now, the way the last round's end does (results saved, Game
  # :completed, turn timers cancelled, post-game window).
  def handle_call(:end_game, _from, state) do
    new_state = auto_end_game(state)
    {:reply, {:ok, to_public(new_state)}, new_state}
  end

  def handle_call({:dissolve_room, actor_id}, _from, state) do
    case authorize(state, actor_id, :dissolve) do
      :ok -> {:stop, :normal, :ok, end_room(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Stroke ops are rate-limited per drawer (check_op_slot/2): an applied or
  # invalid op spends a slot (an invalid one gets the canvas back), a
  # duplicate (a resend: nothing changes, nothing is published) doesn't.
  def handle_call({:append_drawing, actor_id, stroke, op}, _from, state) do
    with :ok <- authorize(state, actor_id, :draw),
         :ok <- check_op_slot(state, actor_id) do
      state |> append_stroke(stroke, op) |> spend_op_slot(actor_id)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:clear_drawing, actor_id, op}, _from, state) do
    with :ok <- authorize(state, actor_id, :draw),
         :ok <- check_op_slot(state, actor_id) do
      state |> clear_strokes(op) |> spend_op_slot(actor_id)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:undo_drawing, actor_id, stroke_id, op}, _from, state) do
    with :ok <- authorize(state, actor_id, :draw),
         :ok <- check_op_slot(state, actor_id) do
      state |> undo_stroke(stroke_id, op) |> spend_op_slot(actor_id)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:member?, user_id}, _from, state) do
    {:reply, member_of?(state, user_id), state}
  end

  def handle_call({:drawing_allowed?, user_id}, _from, state) do
    {:reply, authorize(state, user_id, :draw) == :ok, state}
  end

  # Time-up, scheduled by GameFlow.commit_word_choice/2, only for this game's
  # current round while it is still being drawn: an expiry that fired anyway
  # after everyone guessed (or one for an earlier round) must not score the
  # drawer, capture the round or schedule an advance a second time.
  @impl true
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
         else: {:noreply, notify_waiters(new_state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:auto_advance_round, state) do
    cond do
      state.game_id == nil or state.round_active or state.phase != :round_end ->
        {:noreply, state}

      state.current_round >= state.total_rounds or state.turn_queue == [] ->
        {:noreply, auto_end_game(state)}

      true ->
        {:noreply, auto_next_round(state)}
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
        {:noreply, auto_end_game(state, @no_word_text)}

      true ->
        chosen = Enum.random(state.word_choices)

        case GameFlow.commit_word_choice(state, chosen) do
          {:ok, new_state} ->
            new_state =
              new_state
              |> add_sys_msg("Word auto-selected for the drawer")
              |> notify_waiters()
              |> Broadcasts.push_private_slice()

            {:noreply, new_state}

          {:error, reason} ->
            Logger.warning("room #{state.room_id}: auto-pick failed: #{inspect(reason)}")
            {:noreply, auto_end_game(state, @no_word_text)}
        end
    end
  end

  # The score page's countdown is over. The players who are still members
  # of the room in the DB stay (they come back to its lobby with their final
  # scores, see User :join_room); anyone who left or moved on to another
  # room is dropped, and DB memberships that point here without a player in
  # the room are cleared. Without its creator nobody could join, so such a
  # room is dissolved instead.
  def handle_info(:return_to_lobby, %{status: :post_game} = state) do
    state =
      case Games.get_room_by_id(state.room_id) do
        {:ok, room} ->
          member_ids = MapSet.new(room.players, & &1.id)
          players = Enum.filter(state.players, &MapSet.member?(member_ids, &1.id))
          kept = MapSet.new(players, & &1.id)

          room.players
          |> Enum.reject(&MapSet.member?(kept, &1.id))
          |> Enum.each(&Accounts.leave_room/1)

          %{state | players: players}

        {:error, _} ->
          state
      end

    if creator_present?(state) do
      Games.return_room_to_lobby(state.room_id)

      new_state =
        %{state | status: :lobby, post_game_deadline: nil}
        |> add_sys_msg("Room is back in the lobby. Start a new game!")
        |> notify_waiters()
        |> notify_lobby()

      {:noreply, new_state}
    else
      {:stop, :normal, end_room(%{state | post_game_deadline: nil})}
    end
  end

  def handle_info(:return_to_lobby, state), do: {:noreply, state}

  def handle_info(:stop_self, state) do
    Broadcasts.lobby_room_removed(state.room_id)
    {:stop, :normal, state}
  end

  # The AI pool runs low (GameFlow.start_word_choice/3). The AI call takes
  # seconds, so it runs in a supervised task and its words come back as a
  # message: the room keeps answering meanwhile. One refill at a time, for
  # the room's own answer kind.
  def handle_info({:refill_ai_words, _room_id, total_rounds, ai_tone}, state) do
    if state.prompt not in [nil, ""] and state.game_id != nil and state.ai_refill == nil do
      {:noreply, start_ai_refill(state, total_rounds, ai_tone)}
    else
      {:noreply, state}
    end
  end

  # The refill task's result (Task.Supervisor.async_nolink/2), kept only for
  # the game it was asked for. Filtered again for the room's answer kind
  # (AiWords.filter/2), so the pool only ever holds what the room may offer.
  def handle_info({ref, result}, %{ai_refill: {ref, game_id}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | ai_refill: nil}

    case result do
      {:ok, [_ | _] = words} ->
        if state.game_id == game_id,
          do:
            {:noreply,
             %{state | ai_words: AiWords.filter(words ++ state.ai_words, state.answer_kind)}},
          else: {:noreply, state}

      _failed ->
        {:noreply, state}
    end
  end

  # The refill task died: the next low pool may ask again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ai_refill: {ref, _}} = state),
    do: {:noreply, %{state | ai_refill: nil}}

  # The periodic presence sweep (see the moduledoc and sweep_presence/2).
  def handle_info(:presence_sweep, state) do
    schedule_presence_sweep(state)
    sweep_presence(state, System.monotonic_time(:millisecond))
  end

  # One sweep at the given monotonic `now`, without scheduling the next
  # (tests drive the clock this way).
  def handle_info({:presence_sweep, now}, state) when is_integer(now),
    do: sweep_presence(state, now)

  def handle_info(_msg, state), do: {:noreply, state}

  # A crashed room (the child is :temporary) leaves the home pages' room list
  # too. Normal stops have already said so (end_room/1, :stop_self).
  @impl true
  def terminate(reason, state) when reason not in [:normal, :shutdown] do
    if state.status == :lobby, do: Broadcasts.lobby_room_removed(state.room_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Chat and guesses (submit_message/3) ───────────────────────────────────

  defp clean_message(text) do
    case Scrawly.Text.clean(text, @max_message_length, @max_message_bytes) do
      "" -> {:error, :empty}
      text -> {:ok, text}
    end
  end

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

  # While the word is being drawn, a line that contains it is never stored or
  # broadcast: only the word itself (any `Guess.key/1` variant) from a player
  # who can still score counts as a guess; anything else that contains it is
  # suppressed. Whatever `Guess.matches?/2` accepts, `Guess.contains_word?/2`
  # contains, so a line without the word is chat with one check, unless it is
  # one edit away from the word (`Guess.close?/2`): that one stays private
  # too, from anyone, so a near miss never hands the room a hint.
  defp deliver_message(state, sender, text) do
    word = state.current_word

    cond do
      state.phase != :drawing ->
        {:reply, {:ok, :chat}, append_chat(state, sender, text)}

      Guess.contains_word?(text, word) ->
        if can_score?(state, sender.id) and Guess.matches?(text, word) do
          {new_state, points} = award_guess(state, sender.id)
          {:reply, {:ok, {:correct, points}}, new_state}
        else
          {:reply, {:ok, :suppressed}, state}
        end

      Guess.close?(text, word) ->
        {:reply, {:ok, {:close, close_echo(text)}}, state}

      true ->
        {:reply, {:ok, :chat}, append_chat(state, sender, text)}
    end
  end

  defp close_echo(text) do
    cut = Scrawly.Text.truncate(text, @close_echo_chars, @max_message_bytes)
    if cut == text, do: text, else: String.trim_trailing(cut) <> "…"
  end

  defp can_score?(state, user_id) do
    player?(state, user_id) and user_id != state.current_drawer_id and
      user_id not in state.correct_guessers
  end

  defp append_chat(state, sender, text) do
    GameFlow.push_chat(state, %{
      player_id: sender.id,
      player_name: Map.get(sender, :username) || "Unknown",
      message: text,
      type: :chat
    })
  end

  # Scores a correct guess, posts the :correct_guess line, and ends the round
  # early (scoring the drawer) once every non-drawer player has guessed. The
  # guesser's own channel then gets the word (after the delta that lists
  # them in correct_guessers); nobody else's does.
  defp award_guess(state, player_id) do
    order = length(state.correct_guessers) + 1
    guess_pts = Scoring.guesser_points(time_left(state), state.round_duration, order: order)
    player_name = get_player_name(state.players, player_id)

    new_state =
      %{
        state
        | correct_guessers: [player_id | state.correct_guessers],
          round_guesser_points: state.round_guesser_points ++ [guess_pts]
      }
      |> add_points(player_id, guess_pts)
      |> add_sys_msg("#{player_name} guessed the word! (+#{guess_pts} points)", :correct_guess)

    new_state =
      if all_guessed?(new_state), do: finish_all_guessed(new_state), else: new_state

    new_state =
      new_state
      |> notify_waiters()
      |> Broadcasts.push_private_slice(player_id)

    {new_state, guess_pts}
  end

  # Every player but the drawer has guessed (and there is at least one).
  defp all_guessed?(state) do
    guesser_ids =
      state.players
      |> Enum.reject(&(&1.id == state.current_drawer_id))
      |> Enum.map(& &1.id)

    guesser_ids != [] and Enum.all?(guesser_ids, &(&1 in state.correct_guessers))
  end

  # Everyone guessed: score the drawer (in the room and on their account),
  # end the round early, advance in @round_end_ms. No :room_delta here.
  defp finish_all_guessed(state) do
    drawer_id = state.current_drawer_id
    drawer_pts = Scoring.drawer_round_points(state.round_guesser_points)
    drawer_name = get_player_name(state.players, drawer_id)
    persist_points(drawer_id, drawer_pts)

    %{state | round_active: false, phase: :round_end, round_deadline: nil}
    |> GameFlow.cancel_turn_timers()
    |> add_points(drawer_id, drawer_pts)
    |> capture_round_result(drawer_pts)
    |> add_sys_msg("Everyone guessed! #{drawer_name} earns #{drawer_pts} pts!")
    |> schedule_auto_advance()
  end

  # The round timed out: score the drawer (in the room and on their account),
  # reveal the word, advance in @round_end_ms.
  defp time_up(state) do
    correct_count = length(state.correct_guessers)
    drawer_id = state.current_drawer_id
    drawer_pts = Scoring.drawer_round_points(state.round_guesser_points)
    drawer_name = get_player_name(state.players, drawer_id)
    persist_points(drawer_id, drawer_pts)

    msg =
      if correct_count > 0 do
        "Time's up! The word was: #{state.current_word}. #{drawer_name} earned #{drawer_pts} pts (#{correct_count} guessed)"
      else
        "Time's up! The word was: #{state.current_word}. Nobody guessed."
      end

    %{state | round_deadline: nil, round_active: false, phase: :round_end}
    |> GameFlow.cancel_turn_timers()
    |> add_points(drawer_id, drawer_pts)
    |> capture_round_result(drawer_pts)
    |> add_sys_msg(msg)
    |> notify_waiters()
    |> schedule_auto_advance()
  end

  defp add_points(state, player_id, points) do
    players =
      Enum.map(state.players, fn p ->
        if p.id == player_id, do: %{p | score: (p.score || 0) + points}, else: p
      end)

    %{state | players: players}
  end

  defp schedule_auto_advance(state),
    do:
      GameFlow.track_timer(state, Process.send_after(self(), :auto_advance_round, @round_end_ms))

  # Drawer points go to the account like guess points do (Commands persists
  # those after the room call), so User.score always equals the room score.
  # Runs in the room process: one atomic UPDATE. Ids that aren't UUIDs
  # (hand-built test states) are skipped.
  defp persist_points(user_id, points) when is_integer(points) and points > 0 do
    with {:ok, _uuid} <- Ecto.UUID.cast(user_id),
         {:error, error} <- Accounts.add_score(user_id, points) do
      Logger.error(
        "could not add #{points} drawer points to #{inspect(user_id)}: #{inspect(error)}"
      )
    end

    :ok
  end

  defp persist_points(_user_id, _points), do: :ok

  # A non-creator player leaves. Mid-game: their remaining turns go, the turn
  # ends at once if they were drawing or choosing (word revealed, nobody
  # scores it), the round ends if everyone left has guessed, and the game
  # ends the normal way once fewer than 2 players remain.
  defp player_left(state, player_id) do
    name = get_player_name(state.players, player_id)

    was_drawing? =
      state.game_id != nil and player_id == state.current_drawer_id and
        state.phase in [:choosing, :drawing]

    state =
      %{
        state
        | players: Enum.reject(state.players, &(&1.id == player_id)),
          turn_queue: Enum.reject(state.turn_queue, &(&1 == player_id))
      }
      |> add_sys_msg("#{name} left the room")

    cond do
      state.game_id == nil ->
        state |> notify_waiters() |> notify_lobby()

      length(state.players) < 2 ->
        auto_end_game(state, "Not enough players left, so the game ended.")

      was_drawing? ->
        state |> recount_rounds() |> drawer_left(name) |> notify_waiters()

      state.phase == :drawing and all_guessed?(state) ->
        state |> recount_rounds() |> finish_all_guessed() |> notify_waiters()

      true ->
        state |> recount_rounds() |> notify_waiters()
    end
  end

  # The rounds left are the drawers left in the queue.
  defp recount_rounds(state),
    do: %{state | total_rounds: state.current_round + length(state.turn_queue)}

  # The drawer left mid-turn: end it now, without drawer points (a word
  # being drawn is revealed and the round recorded), and advance.
  defp drawer_left(state, name) do
    {state, msg} =
      if state.phase == :drawing do
        {capture_round_result(state, 0, name),
         "#{name} left while drawing. The word was: #{state.current_word}."}
      else
        {state, "#{name} left while choosing a word, so the turn is skipped."}
      end

    %{
      state
      | phase: :round_end,
        round_active: false,
        round_deadline: nil,
        word_choices: [],
        choice_deadline: nil
    }
    |> GameFlow.cancel_turn_timers()
    |> add_sys_msg(msg)
    |> schedule_auto_advance()
  end

  # The room is dissolved (creator left, dissolve_room, creator gone after a
  # game). Everything is persisted here, before the process stops: its turn
  # timers are cancelled, a running Game is cancelled, and the DB room is
  # :ended with every membership cleared (Games.dissolve_room/1), so nothing
  # can restart it from a stale :lobby status in the meantime.
  defp end_room(state) do
    state = GameFlow.cancel_turn_timers(state)

    if state.game_id, do: log_failure(Games.cancel_game(state.game_id), "cancel its game")
    log_failure(Games.dissolve_room(state.room_id), "persist :ended")

    %{state | players: [], status: :ended}
    |> notify_waiters()
    |> notify_lobby()
  end

  defp log_failure({:error, error}, what),
    do: Logger.error("room could not #{what}: #{inspect(error)}")

  defp log_failure(_ok, _what), do: :ok

  # The DB says :playing, but no game survived the previous process (crash
  # or deploy mid-game): cancel the stale Game, put the room back in the
  # lobby and tell whoever is there.
  defp recover_interrupted_game(%{status: :playing} = state) do
    Games.cancel_interrupted_games(state.room_id)
    log_failure(Games.return_room_to_lobby(state.room_id), "return to the lobby")

    add_sys_msg(
      %{state | status: :lobby},
      "The last game was interrupted, so the room is back in the lobby."
    )
  end

  defp recover_interrupted_game(state), do: state

  # ── Presence (sweep_presence/2) ───────────────────────────────────────────

  defp put_presence_config(state) do
    env = Application.get_env(:scrawly, __MODULE__, [])

    %{
      state
      | presence_sweep_ms: Keyword.get(env, :presence_sweep_ms, @presence_sweep_ms),
        presence_grace_ms: Keyword.get(env, :presence_grace_ms, @presence_grace_ms),
        player_presence_grace_ms:
          Keyword.get(env, :player_presence_grace_ms, @player_presence_grace_ms)
    }
  end

  defp schedule_presence_sweep(%{presence_sweep_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :presence_sweep, ms)

  defp schedule_presence_sweep(_state), do: nil

  # Which members still have a live tab, by OnlineTracker (keyed by
  # Auth.actor_key, like watcher ids; a player's key is their user id):
  # every watcher, and the players while the room is in its lobby. One
  # missing for presence_grace_ms is removed. If the tracker can't answer,
  # nothing changes.
  defp sweep_presence(state, now) do
    lobby_players =
      if state.status == :lobby and state.game_id == nil,
        do: Enum.map(state.players, & &1.id),
        else: []

    candidates = Enum.uniq(Enum.map(state.watchers, & &1.id) ++ lobby_players)

    case live_keys(candidates) do
      {:ok, live} ->
        absent =
          for id <- candidates, not MapSet.member?(live, id), into: %{} do
            {id, Map.get(state.absent_since, id, now)}
          end

        watcher_ids = MapSet.new(state.watchers, & &1.id)

        gone =
          for {id, since} <- absent,
              now - since >= presence_grace_for(state, id, watcher_ids),
              do: id

        remove_absent(%{state | absent_since: Map.drop(absent, gone)}, MapSet.new(gone))

      :error ->
        {:noreply, state}
    end
  end

  defp presence_grace_for(state, id, watcher_ids) do
    if MapSet.member?(watcher_ids, id),
      do: state.presence_grace_ms,
      else: Map.get(state, :player_presence_grace_ms, @player_presence_grace_ms)
  end

  defp live_keys([]), do: {:ok, MapSet.new()}
  defp live_keys(keys), do: ScrawlyWeb.OnlineTracker.live_keys(keys)

  defp remove_absent(state, gone) do
    left_players = Enum.filter(state.players, &(state.status == :lobby and &1.id in gone))
    left_ids = Enum.map(left_players, & &1.id)
    watchers = Enum.reject(state.watchers, &(&1.id in gone))

    cond do
      state.creator_id in left_ids ->
        {:stop, :normal, end_room(%{state | watchers: watchers})}

      left_players != [] ->
        Enum.each(left_ids, &clear_membership(state.room_id, &1))
        names = Enum.map_join(left_players, ", ", & &1.username)

        new_state =
          %{state | watchers: watchers, players: state.players -- left_players}
          |> add_sys_msg("#{names} left the room (no open tab)")
          |> notify_waiters()
          |> notify_lobby()

        {:noreply, new_state}

      length(watchers) != length(state.watchers) ->
        {:noreply, notify_waiters(%{state | watchers: watchers})}

      true ->
        {:noreply, state}
    end
  end

  # The user's DB membership, only if it still points at this room.
  defp clear_membership(room_id, user_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(user_id),
         {:ok, %{current_room_id: ^room_id} = user} <- Accounts.get_user_by_id(user_id) do
      log_failure(Accounts.leave_room(user), "clear a membership")
    end
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

  # The turn order: the players in room order, cycled `total_rounds` times
  # (total_rounds/2 is whole rotations). Every player's room score, and their
  # account score (see User :join_room), starts again from 0. The first
  # round's choices come from the caller, or are picked here when it gave none.
  defp begin_game(state, game_id, total_rounds, opts) do
    player_ids = Enum.map(state.players, & &1.id)
    [drawer_id | turn_queue] = player_ids |> Stream.cycle() |> Enum.take(total_rounds)
    drawer_name = get_player_name(state.players, drawer_id)
    reset_players = Enum.map(state.players, fn p -> %{p | score: 0} end)
    reset_account_scores(player_ids)

    {choices, ai_words} =
      case Map.get(opts, :word_choices) do
        [_ | _] = choices ->
          {choices, Map.get(opts, :ai_words, state.ai_words)}

        _none ->
          {choices, remaining, _used} =
            GameFlow.pick_word_choices(
              Map.get(opts, :ai_words, state.ai_words),
              [],
              state.answer_kind,
              3
            )

          {choices, remaining}
      end

    %{
      state
      | players: reset_players,
        status: :playing,
        last_game_id: nil,
        game_id: game_id,
        current_round: 1,
        total_rounds: total_rounds,
        current_drawer_id: drawer_id,
        turn_queue: turn_queue,
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
        ai_words: ai_words,
        round_guesser_points: [],
        round_start_scores:
          Enum.reduce(reset_players, %{}, fn p, acc -> Map.put(acc, p.id, 0) end)
    }
    |> GameFlow.cancel_turn_timers()
    |> add_sys_msg("Game started! #{drawer_name} is choosing a word \u2026")
    |> GameFlow.enter_word_choice(choices, &schedule_word_choice_timeout/2)
    |> notify_waiters()
    |> Broadcasts.push_private_slice()
  end

  defp reset_account_scores(player_ids) do
    player_ids
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Accounts.reset_scores()
    |> log_failure("reset its players' scores")
  end

  # The drawer's choices go out after the round's :room_delta (see
  # Broadcasts.push_private_slice/1). A round that can't start ends the game.
  defp auto_next_round(state) do
    case GameFlow.start_word_choice(
           state,
           &(&1 |> notify_waiters() |> Broadcasts.push_private_slice()),
           &schedule_word_choice_timeout/2
         ) do
      {:ok, new_state} ->
        new_state

      {:error, reason} ->
        Logger.warning("room #{state.room_id}: next round failed: #{inspect(reason)}")
        auto_end_game(state, "The next round couldn't start, so the game ended.")
    end
  end

  # GameFlow.auto_end_game/3 keeps this field (it updates with %{state | ...}),
  # so the deadline is set before its :room_delta goes out and a page reacting
  # to it reads the time left from get_state/1. `reason` explains an early end.
  defp auto_end_game(state, reason \\ nil) do
    state = %{state | post_game_deadline: schedule_return_to_lobby()}

    state
    |> GameFlow.auto_end_game(&notify_waiters/1, reason)
    |> notify_lobby()
  end

  defp start_ai_refill(state, total_rounds, ai_tone) do
    %{prompt: prompt, answer_kind: answer_kind} = state
    opts = %{num_words: min(max(total_rounds * 3, 9), 60), tone: to_string(ai_tone || :fun)}

    task =
      Task.Supervisor.async_nolink(Scrawly.TaskSupervisor, fn ->
        Games.generate_ai_words(prompt, answer_kind, opts)
      end)

    %{state | ai_refill: {task.ref, state.game_id}}
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

  defp append_stroke(state, stroke, op) do
    with :ok <- fresh_stroke_op(state, op),
         :ok <- new_stroke_id(state, stroke),
         {:ok, stroke} <- StrokeRules.check_append(state.drawing_strokes, stroke) do
      new_state =
        state
        |> put_stroke_op(op)
        |> put_strokes(state.drawing_strokes ++ [stroke])
        |> Broadcasts.publish(:stroke_completed, %{
          stroke_id: stroke.id,
          path: stroke.path,
          color: stroke.color,
          width: stroke.width
        })

      {:reply, :ok, new_state}
    else
      :duplicate ->
        {:reply, :duplicate, state}

      {:error, reason} when reason in [:invalid_stroke, :stroke_limit] ->
        {:reply, {:error, reason, state.drawing_strokes}, state}
    end
  end

  # The clearing tab's epoch goes out with the clear: the drawer's other
  # tabs follow a clear that isn't theirs (drawing_manager.mjs).
  defp op_epoch({epoch, _seq}), do: epoch
  defp op_epoch(_op), do: nil

  defp clear_strokes(state, op) do
    case fresh_stroke_op(state, op) do
      :ok ->
        new_state =
          state
          |> put_stroke_op(op)
          |> put_strokes([])
          |> Broadcasts.publish(:drawing_cleared, %{op_epoch: op_epoch(op)})

        {:reply, :ok, new_state}

      :duplicate ->
        {:reply, :duplicate, state}
    end
  end

  # Only the id goes out: every page already holds the canvas.
  defp undo_stroke(state, stroke_id, op) do
    with :ok <- fresh_stroke_op(state, op),
         {:ok, remaining} <- drop_stroke(state.drawing_strokes, stroke_id) do
      new_state =
        state
        |> put_stroke_op(op)
        |> put_strokes(remaining)
        |> Broadcasts.publish(:drawing_undone, %{stroke_id: stroke_id})

      {:reply, :ok, new_state}
    else
      :duplicate -> {:reply, :duplicate, state}
    end
  end

  # StrokeRules.op_rate_limit/0 per drawer: appends, clears and undos. A
  # refused op doesn't count.
  defp check_op_slot(state, actor_id) do
    {max, window_ms} = StrokeRules.op_rate_limit()
    now = System.monotonic_time(:millisecond)

    recent =
      state.stroke_rate_limits
      |> Map.get(actor_id, [])
      |> Enum.take_while(&(now - &1 < window_ms))

    if length(recent) >= max, do: {:error, :rate_limited}, else: :ok
  end

  defp spend_op_slot({:reply, :duplicate, _state} = result, _actor_id), do: result

  defp spend_op_slot({:reply, reply, state}, actor_id) do
    {_max, window_ms} = StrokeRules.op_rate_limit()
    now = System.monotonic_time(:millisecond)
    {:reply, reply, record_slot(state, :stroke_rate_limits, actor_id, now, window_ms)}
  end

  # A sliding window per key in the map under `field` (key => monotonic ms
  # stamps, newest first): admits and records `now` when the key has fewer
  # than `max` stamps less than `window_ms` old, else `:rate_limited`
  # (refused attempts aren't recorded). Keys left without a recent stamp
  # are dropped, so the map holds only recent actors.
  defp take_slot(state, field, key, now, {max, window_ms}) do
    limits = recent_stamps(Map.fetch!(state, field), now, window_ms)
    recent = Map.get(limits, key, [])

    if length(recent) >= max,
      do: :rate_limited,
      else: {:ok, Map.put(state, field, Map.put(limits, key, [now | recent]))}
  end

  # Records `now` for `key` whatever the count (a watch leave is never
  # refused; a stroke op was checked first).
  defp record_slot(state, field, key, now, window_ms) do
    limits = recent_stamps(Map.fetch!(state, field), now, window_ms)
    Map.put(state, field, Map.update(limits, key, [now], &[now | &1]))
  end

  defp recent_stamps(limits, now, window_ms) do
    Enum.reduce(limits, %{}, fn {key, stamps}, acc ->
      case Enum.take_while(stamps, &(now - &1 < window_ms)) do
        [] -> acc
        recent -> Map.put(acc, key, recent)
      end
    end)
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

  # Stroke changes are published by the handlers (:stroke_completed,
  # :drawing_cleared, :drawing_undone), not by :room_delta.
  defp put_strokes(state, strokes), do: %{state | drawing_strokes: strokes}

  defp via(room_id), do: {:via, Registry, {@registry, room_id}}
  defp creator_present?(state), do: Enum.any?(state.players, &(&1.id == state.creator_id))

  # The home pages' room list (`:lobby` channel): this room's summary while
  # it is listed, its removal otherwise. The summary is also this process's
  # Registry value (nil when not listed), which list_lobby_rooms/0 reads.
  defp notify_lobby(state) do
    summary = if Broadcasts.listed?(state), do: View.lobby_summary(state)
    Registry.update_value(@registry, state.room_id, fn _old -> summary end)
    Broadcasts.notify_lobby(state)
  end

  # The room's public state (View.delta/1: no chat, no strokes, no secrets) to
  # everyone on {:room, room_id}, sequenced. Every phase, turn or membership
  # change goes out this way, so it also tells the members' GameChannels to
  # drop their cached drawing verdict (Broadcasts.drawing_changed/1).
  defp notify_waiters(state) do
    state = Broadcasts.publish(state, :room_delta, View.delta(state))
    Broadcasts.drawing_changed(state.room_id)
    state
  end

  defp to_public(state), do: View.public(state)

  defp to_player_map(user) do
    %{
      id: user.id,
      username: cap_username(user.username),
      score: user.score || 0,
      avatar_id: Map.get(user, :avatar_id) || "a-mushroom",
      avatar_color: Map.get(user, :avatar_color) || "3"
    }
  end

  # Names reach every page in deltas and lobby summaries: an older row
  # might predate the username's byte cap, so they are cut to it here.
  defp cap_name(%{username: name} = member), do: %{member | username: cap_username(name)}
  defp cap_name(member), do: member

  defp cap_username(name) when is_binary(name),
    do: Scrawly.Text.truncate(name, 20, Accounts.User.max_username_bytes())

  defp cap_username(name), do: name

  defp capture_round_result(state, drawer_points, drawer_name \\ nil),
    do: GameFlow.capture_round_result(state, drawer_points, drawer_name)

  defp get_player_name(players, player_id), do: GameFlow.get_player_name(players, player_id)
  defp add_sys_msg(state, text, type \\ :system), do: GameFlow.add_sys_msg(state, text, type)
end
