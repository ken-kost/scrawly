defmodule ScrawlyWeb.Pages.GamePage.Commands do
  @moduledoc """
  Server-side command logic for GamePage.

  All functions here run exclusively on the server — never compiled to JS by Hologram.
  They receive a `%Hologram.Server{}` struct and return one (possibly with a next_action).
  """

  import Hologram.Component, only: [put_action: 2, put_action: 3]

  alias Scrawly.Games
  alias Scrawly.Games.{WordHints, Scoring, RoomServer}

  def poll_room_state(%{room_id: room_id, user_id: user_id}, server) do
    poll_and_enrich(server, room_id, user_id)
  end

  def join_room(%{room_id: room_id, user_id: user_id}, server) do
    with {:ok, user} <- Ash.get(Scrawly.Accounts.User, user_id) do
      player = %{id: user.id, username: user.username, score: user.score || 0}

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

    {first_word, remaining_ai_words} =
      case ai_words do
        [w | rest] -> {w, rest}
        _ -> {nil, []}
      end

    if remaining_ai_words != [] do
      RoomServer.set_ai_words(room_id, remaining_ai_words)
    end

    start_round_opts =
      %{word_count: word_count}
      |> then(fn opts ->
        if first_word, do: Map.put(opts, :override_word, first_word), else: opts
      end)

    with {:ok, _room} <- Games.start_game(room_id),
         {:ok, game} <- Games.create_game(room_id, total_rounds),
         {:ok, updated_game} <- Games.start_round(game.id, first_drawer_id, start_round_opts),
         :ok <- Games.start_round_timer(game.id, round_duration) do
      RoomServer.start_game(room_id, %{
        game_id: game.id,
        round: updated_game.current_round,
        total_rounds: total_rounds,
        drawer_id: first_drawer_id,
        current_word: updated_game.current_word
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
      {:ok, state} -> put_action(server, :room_refreshed, state)
      _ -> server
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
        %{room_id: room_id, player_id: player_id, player_name: player_name} = params,
        server
      ) do
    # Calculate points server-side using actual RoomServer state (ignore client-sent points)
    points =
      case RoomServer.get_state(room_id) do
        {:ok, rs} ->
          word = rs.current_word || ""
          Scoring.guesser_points_with_hints(rs.time_left, rs.round_duration || 60, word)

        _ ->
          # Fallback to client-sent points if RoomServer unavailable
          Map.get(params, :points, 50)
      end

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

    RoomServer.update_player_score(room_id, player_id, points)
    RoomServer.send_chat_message(room_id, sys_msg)
    RoomServer.record_guess(room_id, player_id)
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
        is_drawer = state.current_drawer_id == user_id
        game_active = state.game_id != nil
        word = state.current_word || ""

        word_display =
          cond do
            not game_active ->
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
          if game_active and not is_drawer do
            WordHints.hint_info(word, state.time_left, state.round_duration || 60)
          else
            %{stage: 0, revealed_count: 0, total_letters: 0, remaining_count: 0, progress_pct: 0}
          end

        enriched =
          state
          |> Map.merge(%{
            is_drawer: is_drawer,
            current_word_display: word_display,
            drawer_name: drawer_name,
            hint_info: hint_info
          })
          |> Map.put(:drawing_strokes, [])

        put_action(server, :room_refreshed, enriched)

      {:error, :not_found} ->
        put_action(server, :room_dissolved)
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

        {generated, status} =
          if ws == :ai and p != nil and p != "" do
            case Games.generate_ai_words(p, wc, %{num_words: tr, tone: to_string(tone)}) do
              {:ok, words} when is_list(words) ->
                unique_words = Enum.uniq(words)
                {unique_words, "AI generated #{length(unique_words)}/#{tr} words"}

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
