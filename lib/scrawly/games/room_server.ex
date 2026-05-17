defmodule Scrawly.Games.RoomServer do
  @moduledoc """
  GenServer representing a game room. Single source of truth for room membership,
  game state, chat messages, and drawing data. Clients long-poll via `wait_for_update/3`.

  Subscribes to RoundTimer PubSub to forward timer ticks. Auto-advances rounds
  when timer expires or all players guess correctly.
  """
  use GenServer

  alias Scrawly.Games
  alias Scrawly.Games.{Scoring, RoomServer.GameFlow}

  @registry Scrawly.RoomRegistry
  @supervisor Scrawly.RoomSupervisor

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
    waiters: [],
    # Room settings
    word_count: 1,
    word_source: :local,
    prompt: nil,
    creator_name: nil,
    round_duration: 60,
    round_multiplier: 1,
    ai_tone: :fun,
    # AI-generated word pool (ephemeral, consumed round by round)
    ai_words: [],
    # Words already used this game (to avoid repeats)
    used_words: [],
    # Game state
    game_id: nil,
    current_round: 0,
    total_rounds: 5,
    current_drawer_id: nil,
    current_word: nil,
    time_left: 0,
    round_active: false,
    correct_guessers: [],
    last_game_id: nil,
    # Round results tracking
    round_results: [],
    round_start_scores: %{},
    # Shared chat and drawing
    chat_messages: [],
    drawing_strokes: [],
    # Rate limiting: map of player_id => [monotonic_ms, ...] (recent message timestamps)
    chat_rate_limits: %{},
    # History of completed games in this room
    past_games: []
  ]

  ## Public API

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

  def start_link(room_id), do: GenServer.start_link(__MODULE__, room_id, name: via(room_id))

  def child_spec(room_id) do
    %{id: {__MODULE__, room_id}, start: {__MODULE__, :start_link, [room_id]}, restart: :temporary}
  end

  def get_state(room_id) do
    GenServer.call(via(room_id), :get_state)
  catch
    :exit, _ -> {:error, :not_found}
  end

  def wait_for_update(room_id, known_version, timeout \\ 8_000) do
    GenServer.call(via(room_id), {:wait_for_update, known_version}, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
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

  def set_ai_words(room_id, words) when is_list(words) do
    GenServer.call(via(room_id), {:set_ai_words, words})
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

  def start_game(room_id, params) do
    GenServer.call(via(room_id), {:start_game, params})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def record_guess(room_id, player_id) do
    GenServer.call(via(room_id), {:record_guess, player_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def end_game(room_id) do
    GenServer.call(via(room_id), :end_game)
  catch
    :exit, _ -> {:error, :not_found}
  end

  def dissolve_room(room_id) do
    GenServer.call(via(room_id), :dissolve_room)
  catch
    :exit, _ -> {:error, :not_found}
  end

  def room_exists?(room_id) do
    case Registry.lookup(@registry, room_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  def send_chat_message(room_id, message) do
    GenServer.call(via(room_id), {:send_chat_message, message})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def append_drawing(room_id, path_segment) do
    GenServer.call(via(room_id), {:append_drawing, path_segment})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def clear_drawing(room_id) do
    GenServer.call(via(room_id), :clear_drawing)
  catch
    :exit, _ -> {:error, :not_found}
  end

  def undo_drawing(room_id) do
    GenServer.call(via(room_id), :undo_drawing)
  catch
    :exit, _ -> {:error, :not_found}
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

  ## GenServer Callbacks

  @impl true
  def init(room_id) do
    case Games.get_room_by_id(room_id) do
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
        {:ok, state}

      {:error, _} ->
        {:stop, :room_not_found}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, to_public(state)}, state}
  end

  def handle_call({:wait_for_update, known_version}, from, state) do
    if state.version > known_version do
      {:reply, {:ok, to_public(state)}, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
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
    player = Enum.find(state.players, &(&1.id == player_id))
    player_name = if player, do: player.username, else: "Unknown"

    if player_id == state.creator_id do
      if state.game_id, do: Phoenix.PubSub.unsubscribe(Scrawly.PubSub, "game:#{state.game_id}")

      new_state =
        %{state | players: [], status: :ended}
        |> bump_version()
        |> notify_waiters()

      notify_lobby()
      {:stop, :normal, {:ok, :dissolved}, new_state}
    else
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

    if already_watching do
      {:reply, {:ok, to_public(state)}, state}
    else
      new_state =
        %{state | watchers: state.watchers ++ [watcher]}
        |> add_sys_msg("#{watcher.username} is now watching")
        |> bump_version()
        |> notify_waiters()

      {:reply, {:ok, to_public(new_state)}, new_state}
    end
  end

  def handle_call({:set_ai_words, words}, _from, state) do
    new_state = %{state | ai_words: words}
    {:reply, :ok, new_state}
  end

  def handle_call({:leave_watcher, watcher_id}, _from, state) do
    watcher = Enum.find(state.watchers, &(&1.id == watcher_id))
    watcher_name = if watcher, do: watcher.username, else: "Unknown"

    new_state =
      %{state | watchers: Enum.reject(state.watchers, &(&1.id == watcher_id))}
      |> add_sys_msg("#{watcher_name} stopped watching")
      |> bump_version()
      |> notify_waiters()

    {:reply, {:ok, to_public(new_state)}, new_state}
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

  # ── Game state mutations ─────────────────────────────────────────────

  def handle_call({:start_game, params}, _from, state) do
    Phoenix.PubSub.subscribe(Scrawly.PubSub, "game:#{params.game_id}")
    drawer_name = get_player_name(state.players, params.drawer_id)
    reset_players = Enum.map(state.players, fn p -> %{p | score: 0} end)

    new_state =
      %{
        state
        | players: reset_players,
          status: :playing,
          last_game_id: nil,
          game_id: params.game_id,
          current_round: params.round,
          total_rounds: params.total_rounds,
          current_drawer_id: params.drawer_id,
          current_word: params.current_word,
          time_left: state.round_duration,
          round_active: true,
          correct_guessers: [],
          drawing_strokes: [],
          chat_messages: [],
          round_results: [],
          used_words: if(params.current_word, do: [params.current_word], else: []),
          round_start_scores:
            Enum.reduce(reset_players, %{}, fn p, acc -> Map.put(acc, p.id, 0) end)
      }
      |> add_sys_msg("Game started! Round #{params.round} \u2014 #{drawer_name} is drawing")
      |> bump_version()
      |> notify_waiters()

    notify_lobby()
    {:reply, {:ok, to_public(new_state)}, new_state}
  end

  def handle_call({:record_guess, player_id}, _from, state) do
    new_guessers = [player_id | state.correct_guessers]

    guesser_ids =
      state.players
      |> Enum.reject(&(&1.id == state.current_drawer_id))
      |> Enum.map(& &1.id)

    all_guessed = length(guesser_ids) > 0 and Enum.all?(guesser_ids, &(&1 in new_guessers))

    new_state =
      if all_guessed do
        Games.stop_round_timer(state.game_id)
        Process.send_after(self(), :auto_advance_round, 3_000)

        total_guessers = length(guesser_ids)
        drawer_pts = Scoring.drawer_points(length(new_guessers), total_guessers)
        drawer_name = get_player_name(state.players, state.current_drawer_id)

        updated_players =
          Enum.map(state.players, fn p ->
            if p.id == state.current_drawer_id,
              do: %{p | score: (p.score || 0) + drawer_pts},
              else: p
          end)

        %{
          state
          | players: updated_players,
            correct_guessers: new_guessers,
            round_active: false,
            time_left: 0
        }
        |> capture_round_result(drawer_pts)
        |> add_sys_msg("Everyone guessed! #{drawer_name} earns #{drawer_pts} pts!")
      else
        %{state | correct_guessers: new_guessers}
      end
      |> bump_version()
      |> notify_waiters()

    {:reply, {:ok, to_public(new_state)}, new_state}
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
      |> bump_version()
      |> notify_waiters()

    notify_lobby()
    Process.send_after(self(), :return_to_lobby, 30_000)

    {:reply, {:ok, to_public(new_state)}, new_state}
  end

  def handle_call(:dissolve_room, _from, state) do
    if state.game_id, do: Phoenix.PubSub.unsubscribe(Scrawly.PubSub, "game:#{state.game_id}")

    new_state =
      %{state | players: [], status: :ended}
      |> bump_version()
      |> notify_waiters()

    notify_lobby()
    {:stop, :normal, :ok, new_state}
  end

  # ── Chat & Drawing ──────────────────────────────────────────────────

  @chat_max_messages 3
  @chat_window_ms 5_000

  def handle_call({:send_chat_message, message}, _from, state) do
    type = Map.get(message, :type)
    player_name = Map.get(message, :player_name)

    # System messages always bypass rate limiting.
    if type in [:system, :correct_guess] or player_name == "System" do
      new_state =
        %{state | chat_messages: [message | state.chat_messages] |> Enum.take(50)}
        |> bump_version()
        |> notify_waiters()

      {:reply, :ok, new_state}
    else
      now = System.monotonic_time(:millisecond)
      key = player_name || "unknown"

      recent =
        state.chat_rate_limits |> Map.get(key, []) |> Enum.filter(&(now - &1 < @chat_window_ms))

      if length(recent) >= @chat_max_messages do
        {:reply, {:error, :rate_limited}, state}
      else
        new_limits = Map.put(state.chat_rate_limits, key, [now | recent])

        new_state =
          %{
            state
            | chat_messages: [message | state.chat_messages] |> Enum.take(50),
              chat_rate_limits: new_limits
          }
          |> bump_version()
          |> notify_waiters()

        {:reply, :ok, new_state}
      end
    end
  end

  def handle_call({:append_drawing, stroke}, _from, state) when is_map(stroke) do
    new_state =
      %{state | drawing_strokes: state.drawing_strokes ++ [stroke]}
      |> bump_version()
      |> notify_waiters(false)

    {:reply, :ok, new_state}
  end

  # Legacy: plain string segment (backward compat)
  def handle_call({:append_drawing, segment}, _from, state) when is_binary(segment) do
    stroke = %{path: segment, color: "#000000", width: 2}

    new_state =
      %{state | drawing_strokes: state.drawing_strokes ++ [stroke]}
      |> bump_version()
      |> notify_waiters(false)

    {:reply, :ok, new_state}
  end

  def handle_call(:clear_drawing, _from, state) do
    new_state =
      %{state | drawing_strokes: []}
      |> bump_version()
      |> notify_waiters(false)

    {:reply, :ok, new_state}
  end

  def handle_call(:undo_drawing, _from, state) do
    new_strokes =
      case state.drawing_strokes do
        [] -> []
        strokes -> Enum.drop(strokes, -1)
      end

    new_state =
      %{state | drawing_strokes: new_strokes}
      |> bump_version()
      |> notify_waiters(false)

    {:reply, {:ok, new_strokes}, new_state}
  end

  # ── PubSub handlers (RoundTimer events) ──────────────────────────────

  @impl true
  def handle_info({:timer_update, %{remaining_seconds: seconds}}, state) do
    new_state = %{state | time_left: seconds} |> bump_version() |> notify_waiters()
    {:noreply, new_state}
  end

  def handle_info({:timer_started, %{duration_seconds: seconds}}, state) do
    new_state =
      %{state | time_left: seconds, round_active: true} |> bump_version() |> notify_waiters()

    {:noreply, new_state}
  end

  def handle_info({:round_ended, %{reason: :time_up}}, state) do
    total_guessers = length(state.players) - 1
    correct_count = length(state.correct_guessers)
    drawer_pts = Scoring.drawer_points(correct_count, total_guessers, time_up: true)
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
        "Time's up! The word was: #{state.current_word}. #{drawer_name} gets #{drawer_pts} pts"
      end

    new_state =
      %{state | players: updated_players, time_left: 0, round_active: false}
      |> capture_round_result(drawer_pts)
      |> add_sys_msg(msg)
      |> bump_version()
      |> notify_waiters()

    Process.send_after(self(), :auto_advance_round, 3_000)
    {:noreply, new_state}
  end

  def handle_info(:auto_advance_round, state) do
    if state.game_id && not state.round_active do
      if state.current_round >= state.total_rounds do
        {:noreply, auto_end_game(state)}
      else
        {:noreply, auto_next_round(state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:return_to_lobby, state) do
    if state.status == :post_game do
      Games.return_room_to_lobby(state.room_id)

      # Clear players — they'll re-join when they land on the GamePage
      new_state =
        %{state | status: :lobby, players: []}
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
    # Skip refill if no prompt is set or game ended
    if state.prompt && state.prompt != "" && state.game_id do
      tone_str = to_string(ai_tone || :fun)
      num_words = max(total_rounds, 5)

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

  ## Private — Auto advance

  defp auto_next_round(state) do
    GameFlow.auto_next_round(state, &bump_version/1, &notify_waiters/1)
  end

  defp auto_end_game(state) do
    notify_lobby()
    Process.send_after(self(), :return_to_lobby, 30_000)
    GameFlow.auto_end_game(state, &bump_version/1, &notify_waiters/1)
  end

  ## Private — Helpers

  defp via(room_id), do: {:via, Registry, {@registry, room_id}}
  defp creator_present?(state), do: Enum.any?(state.players, &(&1.id == state.creator_id))
  defp bump_version(state), do: %{state | version: state.version + 1}
  defp notify_lobby, do: Phoenix.PubSub.broadcast(Scrawly.PubSub, "lobby:rooms", :rooms_updated)

  defp notify_waiters(state, broadcast \\ true) do
    public = to_public(state)
    Enum.each(state.waiters, fn from -> GenServer.reply(from, {:ok, public}) end)

    if broadcast do
      Phoenix.PubSub.broadcast(Scrawly.PubSub, "room:#{state.room_id}", :room_state_changed)
    end

    %{state | waiters: []}
  end

  defp to_public(state) do
    Map.take(state, [
      :room_id,
      :name,
      :code,
      :status,
      :creator_id,
      :max_players,
      :players,
      :watchers,
      :version,
      :game_id,
      :current_round,
      :total_rounds,
      :current_drawer_id,
      :current_word,
      :time_left,
      :round_active,
      :correct_guessers,
      :chat_messages,
      :drawing_strokes,
      :last_game_id,
      :round_results,
      :word_count,
      :word_source,
      :prompt,
      :creator_name,
      :round_duration,
      :round_multiplier,
      :ai_tone,
      :past_games
    ])
  end

  defp to_player_map(user), do: %{id: user.id, username: user.username, score: user.score || 0}

  defp capture_round_result(state, drawer_points),
    do: GameFlow.capture_round_result(state, drawer_points)

  defp get_player_name(players, player_id), do: GameFlow.get_player_name(players, player_id)
  defp add_sys_msg(state, text), do: GameFlow.add_sys_msg(state, text)
end
