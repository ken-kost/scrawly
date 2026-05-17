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
    end

    resource Scrawly.Games.Word do
      # Word selection code interfaces
      define :get_all_words, action: :list_all
      define :list_words_by_difficulty, action: :list_by_difficulty, args: [:difficulty]
    end
  end

  # Helper functions for word management
  def get_random_word(opts \\ []) do
    difficulty = opts[:difficulty]

    result =
      if difficulty do
        case list_words_by_difficulty(difficulty) do
          {:ok, [_ | _] = words} -> {:ok, words}
          _ -> {:error, :no_words}
        end
      else
        case get_all_words() do
          {:ok, [_ | _] = words} -> {:ok, words}
          _ -> {:error, :no_words}
        end
      end

    case result do
      {:ok, words} -> {:ok, Enum.random(words).text}
      {:error, reason} -> {:error, reason}
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

  # Round timer helper functions
  def start_round_timer(game_id) do
    Scrawly.Games.RoundTimer.start_timer(game_id)
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
