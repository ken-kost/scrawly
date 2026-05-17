defmodule Scrawly.Games do
  use Ash.Domain,
    otp_app: :scrawly,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Scrawly.Games.Room do
      # Room management code interfaces
      define :create_room, action: :create
      define :get_rooms, action: :read
      define :get_room_by_id, action: :read, get_by: [:id]
      define :get_room_by_code, action: :read, get_by: :code
      define :join_room, action: :join_room, args: [:player_id]
      define :auto_start_if_ready, action: :auto_start_if_ready
      define :handle_player_disconnect, action: :handle_player_disconnect, args: [:player_id]
      define :start_game, action: :start_game
      define :end_game, action: :end_game
      define :set_room_post_game, action: :post_game
      define :return_room_to_lobby, action: :return_to_lobby

      # AI word generation
      define :generate_ai_words, action: :generate_ai_words, args: [:prompt, :word_count]
    end

    resource Scrawly.Games.Game do
      # Game flow code interfaces
      define :create_game, action: :start_game, args: [:room_id, :total_rounds]
      define :get_game_by_id, action: :read, get_by: [:id]
      define :get_game_by_room, action: :get_by_room, args: [:room_id]
      define :start_round, action: :start_round, args: [:current_drawer_id]
      define :select_next_drawer, action: :select_next_drawer, args: [:player_queue]
      define :next_round, action: :next_round
      define :complete_round, action: :complete_round
      define :end_current_game, action: :end_game
      define :save_round_details, action: :save_round_details, args: [:round_details]
      define :get_games_for_room, action: :for_room, args: [:room_id]
    end

    resource Scrawly.Games.Word do
      # Word selection code interfaces
      define :get_all_words, action: :list_all
      define :get_words_by_difficulty, action: :list_by_difficulty, args: [:difficulty]

      define :get_words_by_difficulty_and_word_count,
        action: :list_by_difficulty_and_word_count,
        args: [:difficulty, :word_count]
    end

    resource Scrawly.Games.GameResult do
      define :create_game_result, action: :create
      define :get_game_results_for_player, action: :for_player, args: [:player_id]
      define :get_game_results_for_game, action: :for_game, args: [:game_id]
    end
  end

  # Save game results for all players when a game ends.
  def save_game_results(game_id, room_id, players, round_results \\ []) do
    Enum.each(players, fn player ->
      create_game_result(%{
        player_id: player.id,
        game_id: game_id,
        room_id: room_id,
        score: player.score || 0,
        player_username: player.username
      })
    end)

    # Save per-round breakdown to the Game record
    if round_results != [] do
      save_round_details(game_id, round_results)
    end
  end

  # Dissolves a room: kicks all players and marks it as ended.
  # Called when the creator leaves the room.
  def dissolve_room(room_id) do
    with {:ok, room} <- get_room_by_id(room_id) do
      # Leave all players from the room
      Enum.each(room.players, fn player ->
        Scrawly.Accounts.leave_room(player)
      end)

      # Mark room as ended
      room
      |> Ash.Changeset.for_update(:end_game, %{})
      |> Ash.update()
    end
  end

  # Word selection with optional difficulty weighting, word_count filter, and exclusion.
  #
  # Options:
  #   - :difficulty - :easy, :medium, or :hard (default: weighted random)
  #   - :word_count - 1, 2, or 3 (default: 1)
  #   - :exclude - list of word strings to avoid repeating
  def get_random_word(opts \\ []) do
    difficulty = Keyword.get(opts, :difficulty) || weighted_random_difficulty()
    exclude = Keyword.get(opts, :exclude, [])
    word_count = Keyword.get(opts, :word_count, 1)

    case get_words_by_difficulty_and_word_count(difficulty, word_count) do
      {:ok, words} ->
        available = Enum.reject(words, fn w -> w.text in exclude end)

        # Fall back to unfiltered if exclusion eliminates everything
        pool = if available == [], do: words, else: available

        case pool do
          [] ->
            {:error, "No words available for word_count=#{word_count}, difficulty=#{difficulty}"}

          _ ->
            {:ok, Enum.random(pool).text}
        end

      error ->
        error
    end
  end

  def generate_hint(word) when is_binary(word) do
    word
    |> String.graphemes()
    |> Enum.map(fn
      " " -> "  "
      _ -> "_"
    end)
    |> Enum.join(" ")
  end

  def obfuscate_word(word, _drawer_id) do
    generate_hint(word)
  end

  def get_word_count do
    case get_all_words() do
      {:ok, words} -> length(words)
      _ -> 0
    end
  end

  defp weighted_random_difficulty do
    roll = :rand.uniform(100)

    cond do
      roll <= 30 -> :easy
      roll <= 80 -> :medium
      true -> :hard
    end
  end

  # Round timer helper functions
  def start_round_timer(game_id, duration_seconds \\ 60) do
    Scrawly.Games.RoundTimer.start_timer(game_id, duration_seconds)
  end

  def stop_round_timer(game_id) do
    Scrawly.Games.RoundTimer.stop_timer(game_id)
  end

  def get_round_time_remaining(game_id) do
    Scrawly.Games.RoundTimer.get_remaining_time(game_id)
  end

  @round_duration 80

  def get_round_duration, do: @round_duration

  def calculate_points(time_remaining) when time_remaining >= 0 do
    base_points = 100
    time_bonus = round(time_remaining / @round_duration * 100)
    base_points + time_bonus
  end

  def process_guess(guesser_id, drawer_id, game_id) do
    case get_game_by_id(game_id) do
      {:ok, game} ->
        current_word = game.current_word
        drawer_id_db = game.current_drawer_id

        cond do
          guesser_id == drawer_id_db ->
            {:error, :drawer_cannot_guess}

          current_word == nil ->
            {:error, :no_active_round}

          true ->
            {:ok, current_word, drawer_id_db}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def award_points_to_guesser(guesser_id, points) do
    case Ash.get(Scrawly.Accounts.User, guesser_id) do
      {:ok, user} ->
        new_score = (user.score || 0) + points
        Scrawly.Accounts.update_score(user, %{score: new_score})
        {:ok, new_score}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def award_points_to_drawer(drawer_id, points) do
    case Ash.get(Scrawly.Accounts.User, drawer_id) do
      {:ok, user} ->
        new_score = (user.score || 0) + points
        Scrawly.Accounts.update_score(user, %{score: new_score})
        {:ok, new_score}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
