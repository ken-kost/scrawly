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
      define :create_room, action: :create_room
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
      define :start_round, action: :start_round, args: [:current_drawer_id]
      define :select_next_drawer, action: :select_next_drawer, args: [:player_queue]
      define :next_round, action: :next_round
      define :complete_round, action: :complete_round
      define :end_current_game, action: :end_game
    end

    resource Scrawly.Games.Word do
      # Word selection code interfaces
      define :get_all_words, action: :list_all
    end
  end

  # Helper functions for word management
  def get_random_word do
    case get_all_words() do
      {:ok, []} -> {:error, "No words available"}
      {:ok, words} -> {:ok, Enum.random(words).text}
      error -> error
    end
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
end
