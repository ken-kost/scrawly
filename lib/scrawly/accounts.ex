defmodule Scrawly.Accounts do
  use Ash.Domain, otp_app: :scrawly, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Scrawly.Accounts.Token

    resource Scrawly.Accounts.User do
      define :register_with_password, action: :register_with_password, args: [:email, :password]
      define :sign_in_with_password, action: :sign_in_with_password, args: [:email, :password]
      define :join_room, action: :join_room, args: [:current_room_id]
      define :leave_room, action: :leave_room
      define :update_dark_mode, action: :update_dark_mode, args: [:dark_mode]
      define :update_accent_color, action: :update_accent_color, args: [:accent_color]
    end
  end
end
