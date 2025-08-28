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

    resource Scrawly.Games.Game
  end
end
