defmodule ScrawlyWeb.Pages.GamePage.Commands do
  @moduledoc """
  Server-side command logic for GamePage.

  All functions here run exclusively on the server — never compiled to JS by Hologram.
  They receive a `%Hologram.Server{}` struct and return one (possibly with a next_action).
  """

  import Hologram.Component, only: [put_action: 2, put_action: 3]

  alias Scrawly.Games
  alias Scrawly.Games.{WordHints, RoomServer}
  alias Scrawly.Games.RoomServer.GameFlow

  def poll_room_state(%{room_id: room_id, user_id: user_id}, server) do
    poll_and_enrich(server, room_id, user_id)
  end

  def join_room(%{room_id: room_id, user_id: user_id}, server) do
    with {:ok, user} <- Ash.get(Scrawly.Accounts.User, user_id) do
      player = %{
        id: user.id,
        username: user.username,
        score: user.score || 0,
        avatar_id: user.avatar_id || "a-mushroom",
        avatar_color: user.avatar_color || "3"
      }

      case RoomServer.join(room_id, player) do
        {:ok, _state} ->
          Scrawly.Accounts.join_room(user_id, room_id)
          Games.join_room(room_id, user_id)

          # Notify already-connected channel clients about the new player.
          case RoomServer.get_state(room_id) do
            {:ok, rs} ->
              ScrawlyWeb.Endpoint.broadcast("game:#{rs.code}", "room_state_changed", %{})

            _ ->
              :ok
          end

          poll_and_enrich(server, room_id, user_id)

        {:error, :room_full} ->
          put_action(server, :switch_to_watcher)

        {:error, _} ->
          server
      end
    else
      {:error, _} -> server
    end
  end

  def join_as_watcher(%{room_id: room_id, user_id: user_id, username: username}, server) do
    watcher_name = if username == "" or username == nil, do: "Guest", else: username
    watcher = %{id: user_id || "guest-#{:rand.uniform(100_000)}", username: watcher_name}

    case RoomServer.join_as_watcher(room_id, watcher) do
      {:ok, state} -> put_action(server, :room_refreshed, state)
      {:error, _} -> server
    end
  end

  def leave_watcher(%{room_id: room_id, watcher_id: watcher_id}, server) do
    RoomServer.leave_watcher(room_id, watcher_id)
    put_action(server, :go_home)
  end

  def start_game(%{room_id: room_id, players: players}, server) do
    first_drawer_id = List.first(players).id

    {word_count, _word_source, ai_words, round_duration, total_rounds, ai_status} =
      fetch_room_game_settings(room_id, players)

    # Build 3 word choices for the first drawer (AI pool first, fall back to local).
    {choices, remaining_ai, _used_from_ai} =
      GameFlow.pick_word_choices(ai_words, [], word_count, 3)

    if remaining_ai != [] do
      RoomServer.set_ai_words(room_id, remaining_ai)
    end

    with {:ok, _room} <- Games.start_game(room_id),
         {:ok, game} <- Games.create_game(room_id, total_rounds) do
      RoomServer.start_game(room_id, %{
        game_id: game.id,
        round: 1,
        total_rounds: total_rounds,
        drawer_id: first_drawer_id,
        word_choices: choices,
        round_duration: round_duration
      })

      if ai_status do
        sys_msg = %{
          id: :rand.uniform(100_000),
          player_name: "System",
          message: ai_status,
          timestamp: DateTime.utc_now(),
          type: :system
        }

        RoomServer.send_chat_message(room_id, sys_msg)
      end
    end

    case RoomServer.get_state(room_id) do
      {:ok, state} -> put_action(server, :room_refreshed, enrich_state(state, get_user_id(server)))
      _ -> server
    end
  end

  def choose_word(%{room_id: room_id, player_id: player_id, word: word}, server) do
    case RoomServer.choose_word(room_id, player_id, word) do
      {:ok, _state} ->
        case RoomServer.get_state(room_id) do
          {:ok, state} ->
            put_action(server, :room_refreshed, enrich_state(state, player_id))

          _ ->
            server
        end

      {:error, _} ->
        server
    end
  end

  def end_game(%{game_id: game_id, room_id: room_id}, server) do
    if game_id do
      Games.stop_round_timer(game_id)
      Games.end_current_game(game_id)
      Games.end_game(room_id)
      RoomServer.end_game(room_id)
    end

    server
  end

  def leave_room(%{user_id: user_id, room_id: room_id, is_creator: is_creator}, server) do
    RoomServer.leave(room_id, user_id)

    if is_creator do
      Games.dissolve_room(room_id)
    else
      with {:ok, user} <- Ash.get(Scrawly.Accounts.User, user_id),
           do: Scrawly.Accounts.leave_room(user)
    end

    put_action(server, :go_home)
  end

  def send_chat_message(%{room_id: room_id, message: message}, server) do
    full_msg =
      Map.merge(message, %{
        id: :rand.uniform(100_000),
        timestamp: DateTime.utc_now()
      })

    RoomServer.send_chat_message(room_id, full_msg)
    server
  end

  def record_correct_guess(
        %{room_id: room_id, player_id: player_id, player_name: player_name} = _params,
        server
      ) do
    # RoomServer.record_guess is the source of truth — it computes points using
    # the authoritative scoring formula and updates the in-game player score.
    case RoomServer.record_guess(room_id, player_id) do
      {:ok, _state, points} when points > 0 ->
        # Persist score to user profile (cross-game total)
        with {:ok, user} <- Ash.get(Scrawly.Accounts.User, player_id) do
          new_score = (user.score || 0) + points
          user |> Ash.Changeset.for_update(:update_score, %{score: new_score}) |> Ash.update()
        end

        sys_msg = %{
          id: :rand.uniform(100_000),
          player_name: "System",
          message: "#{player_name} guessed the word! (+#{points} points)",
          timestamp: DateTime.utc_now(),
          type: :correct_guess
        }

        RoomServer.send_chat_message(room_id, sys_msg)

      _ ->
        :ok
    end

    server
  end

  def fetch_past_games(%{room_id: room_id}, server) do
    games =
      case Games.get_games_for_room(room_id) do
        {:ok, games} ->
          Enum.map(games, fn g ->
            # Fetch top scorer for this game
            winner =
              case Games.get_game_results_for_game(g.id) do
                {:ok, results} when results != [] ->
                  top = Enum.max_by(results, & &1.score, fn -> nil end)
                  if top, do: %{username: top.player_username, score: top.score}, else: nil

                _ ->
                  nil
              end

            %{id: g.id, created_at: g.created_at, total_rounds: g.total_rounds, winner: winner}
          end)

        _ ->
          []
      end

    put_action(server, :past_games_loaded, games: games)
  end

  ## Private

  # Reads RoomServer state, computes per-user fields (word hint, drawer name, is_drawer),
  # and returns a room_refreshed action with the enriched map.
  defp poll_and_enrich(server, room_id, user_id) do
    case RoomServer.get_state(room_id) do
      {:ok, state} ->
        put_action(server, :room_refreshed, enrich_state(state, user_id))

      {:error, :not_found} ->
        put_action(server, :room_dissolved)
    end
  end

  # Enriches public RoomServer state with per-user fields:
  #   - is_drawer
  #   - current_word_display (masked for non-drawers)
  #   - drawer_name
  #   - hint_info
  #   - word_choices (only for the drawer; empty list for others)
  #   - choice_time_left (seconds remaining in choice phase)
  defp enrich_state(state, user_id) do
    is_drawer = state.current_drawer_id == user_id
    game_active = state.game_id != nil
    word = state.current_word || ""
    phase = Map.get(state, :phase, :idle)

    word_display =
      cond do
        not game_active ->
          ""

        phase == :choosing ->
          ""

        is_drawer ->
          word

        state.time_left > 0 ->
          WordHints.generate_hint(word, state.time_left, state.round_duration || 60)

        true ->
          WordHints.hidden_display(word, state.round_duration || 60)
      end

    drawer_name =
      case Enum.find(state.players, &(&1.id == state.current_drawer_id)) do
        nil -> "Unknown"
        p -> p.username
      end

    hint_info =
      if game_active and not is_drawer and phase == :drawing do
        WordHints.hint_info(word, state.time_left, state.round_duration || 60)
      else
        %{stage: 0, revealed_count: 0, total_letters: 0, remaining_count: 0, progress_pct: 0}
      end

    # Only the drawer sees the actual word choices; everyone else gets empty.
    word_choices = if is_drawer, do: Map.get(state, :word_choices, []), else: []

    choice_time_left =
      case Map.get(state, :choice_deadline) do
        nil ->
          0

        deadline when is_integer(deadline) ->
          now = System.monotonic_time(:millisecond)
          max(0, div(deadline - now + 999, 1000))
      end

    state
    |> Map.merge(%{
      is_drawer: is_drawer,
      current_word_display: word_display,
      drawer_name: drawer_name,
      hint_info: hint_info,
      word_choices: word_choices,
      choice_time_left: choice_time_left,
      phase: phase
    })
    |> Map.put(:drawing_strokes, [])
  end

  defp get_user_id(server) do
    case server do
      %{session: %{user_id: id}} -> id
      _ -> nil
    end
  end

  defp fetch_room_game_settings(room_id, players) do
    case RoomServer.get_state(room_id) do
      {:ok, rs} ->
        wc = rs.word_count || 1
        ws = rs.word_source || :local
        p = rs.prompt
        rd = rs.round_duration || 60
        rm = rs.round_multiplier || 1
        tone = rs.ai_tone || :fun
        tr = length(players) * rm
        # 3 choices per round; cap at 60 to limit prompt size.
        ai_num_words = min(max(tr * 3, 9), 60)

        {generated, status} =
          if ws == :ai and p != nil and p != "" do
            case Games.generate_ai_words(p, wc, %{num_words: ai_num_words, tone: to_string(tone)}) do
              {:ok, words} when is_list(words) ->
                unique_words = Enum.uniq(words)
                {unique_words, "AI generated #{length(unique_words)}/#{ai_num_words} words"}

              {:error, reason} ->
                {[], "AI failed: #{inspect(reason)} — falling back to local words"}

              _ ->
                {[], "AI returned unexpected response — falling back to local words"}
            end
          else
            {[], nil}
          end

        {wc, ws, generated, rd, tr, status}

      _ ->
        {1, :local, [], 60, length(players), nil}
    end
  end
end
