defmodule Scrawly.Games.RoomServer do
  @moduledoc """
  GenServer representing a game room. Single source of truth for room membership,
  game state, chat messages, and drawing data. State changes are projected to
  subscribed game pages via Hologram realtime (`:room_delta` / `:chat_appended`).

  Subscribes to RoundTimer PubSub to forward timer ticks. Auto-advances rounds
  when timer expires or all players guess correctly.
  """
  use GenServer

  alias Scrawly.Games
  alias Scrawly.Games.{Scoring, RoomServer.GameFlow}

  @registry Scrawly.RoomRegistry
  @supervisor Scrawly.RoomSupervisor
  @max_watchers 50

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
    time_left: 0,
    round_active: false,
    correct_guessers: [],
    last_game_id: nil,
    phase: :idle,
    word_choices: [],
    choice_deadline: nil,
    round_guesser_points: [],
    round_results: [],
    round_start_scores: %{},
    chat_messages: [],
    drawing_strokes: [],
    chat_rate_limits: %{},
    past_games: []
  ]

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

  def record_guess(room_id, player_id) do
    GenServer.call(via(room_id), {:record_guess, player_id})
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
  """
  @spec authorize(map, term, :start_game | :dissolve | :leave) :: :ok | {:error, atom}
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

  defp creator?(state, actor_id), do: actor_id != nil and actor_id == state.creator_id
  defp player?(state, actor_id), do: Enum.any?(state.players, &(&1.id == actor_id))

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

  def handle_call({:record_guess, player_id}, _from, state) do
    cond do
      state.phase != :drawing ->
        {:reply, {:error, :round_not_active}, state}

      player_id in state.correct_guessers ->
        {:reply, {:ok, to_public(state), 0}, state}

      true ->
        order = length(state.correct_guessers) + 1
        guess_pts = Scoring.guesser_points(state.time_left, state.round_duration, order: order)
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

        intermediate = %{
          state
          | players: updated_players,
            correct_guessers: new_guessers,
            round_guesser_points: new_round_points
        }

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
                time_left: 0
            }
            |> capture_round_result(drawer_pts)
            |> add_sys_msg("Everyone guessed! #{drawer_name} earns #{drawer_pts} pts!")
          else
            intermediate
          end
          |> bump_version()
          |> notify_waiters()

        {:reply, {:ok, to_public(new_state), guess_pts}, new_state}
    end
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
          phase: :idle,
          word_choices: [],
          choice_deadline: nil,
          round_guesser_points: [],
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

  def handle_call({:dissolve_room, actor_id}, _from, state) do
    case authorize(state, actor_id, :dissolve) do
      :ok -> {:stop, :normal, :ok, end_room(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @chat_max_messages 3
  @chat_window_ms 5_000

  def handle_call({:send_chat_message, message}, _from, state) do
    type = Map.get(message, :type)
    player_name = Map.get(message, :player_name)

    if type in [:system, :correct_guess] or player_name == "System" do
      new_state =
        %{state | chat_messages: [message | state.chat_messages] |> Enum.take(50)}
        |> bump_version()
        |> notify_waiters(false)

      broadcast_chat_appended(state.room_id, message)
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
          |> notify_waiters(false)

        broadcast_chat_appended(state.room_id, message)
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
      %{state | players: updated_players, time_left: 0, round_active: false, phase: :round_end}
      |> capture_round_result(drawer_pts)
      |> add_sys_msg(msg)
      |> bump_version()
      |> notify_waiters()

    Process.send_after(self(), :auto_advance_round, 3_000)
    {:noreply, new_state}
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
        time_left: state.round_duration,
        round_active: false,
        correct_guessers: [],
        drawing_strokes: [],
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

  defp auto_end_game(state) do
    notify_lobby()
    Process.send_after(self(), :return_to_lobby, 30_000)
    GameFlow.auto_end_game(state, &bump_version/1, &notify_waiters/1)
  end

  defp schedule_word_choice_timeout(game_id, round) do
    Process.send_after(self(), {:word_choice_timeout, game_id, round}, 15_000)
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

  defp broadcast_chat_appended(room_id, message) do
    Hologram.Realtime.broadcast_action({:room, room_id}, :chat_appended, %{message: message})
  end

  defp public_delta(state) do
    %{
      room_id: state.room_id,
      status: state.status,
      players: state.players,
      watchers: state.watchers,
      version: state.version,
      game_id: state.game_id,
      current_round: state.current_round,
      total_rounds: state.total_rounds,
      current_drawer_id: state.current_drawer_id,
      time_left: state.time_left,
      round_active: state.round_active,
      correct_guessers: state.correct_guessers,
      phase: state.phase,
      choice_time_left: choice_time_left(state),
      last_game_id: state.last_game_id,
      max_players: state.max_players,
      past_games: state.past_games
    }
  end

  defp choice_time_left(state) do
    case state.choice_deadline do
      nil ->
        0

      deadline when is_integer(deadline) ->
        now = System.monotonic_time(:millisecond)
        max(0, div(deadline - now + 999, 1000))
    end
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
      :past_games,
      :phase,
      :word_choices,
      :choice_deadline
    ])
  end

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
  defp add_sys_msg(state, text), do: GameFlow.add_sys_msg(state, text)
end
