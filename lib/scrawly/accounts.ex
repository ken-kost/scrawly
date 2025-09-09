defmodule Scrawly.Accounts do
  use Ash.Domain, otp_app: :scrawly, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Scrawly.Accounts.Token

    resource Scrawly.Accounts.User do
      define :create_user, action: :create, args: [:email]
      define :join_room, action: :join_room, args: [:current_room_id]
    end
  end
end
