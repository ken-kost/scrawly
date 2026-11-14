defmodule Scrawly.Accounts do
  use Ash.Domain, otp_app: :scrawly, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Scrawly.Accounts.Token

    resource Scrawly.Accounts.User do
      define :get_user_by_id, action: :read, get_by: [:id], not_found_error?: false
      define :register_with_password, action: :register_with_password, args: [:email, :password]
      define :register_as_guest, action: :register_as_guest
      define :upgrade_guest, action: :upgrade_guest
      define :sign_in_with_password, action: :sign_in_with_password, args: [:email, :password]
      define :join_room, action: :join_room, args: [:current_room_id]
      define :leave_room, action: :leave_room
      define :add_score, action: :add_score, args: [:points]
      define :update_dark_mode, action: :update_dark_mode, args: [:dark_mode]
      define :update_accent_color, action: :update_accent_color, args: [:accent_color]
      define :update_profile, action: :update_profile
      define :change_password, action: :change_password

      define :reset_password_with_recovery_code,
        action: :reset_password_with_recovery_code,
        args: [:email, :recovery_code, :password, :password_confirmation]

      define :regenerate_recovery_code,
        action: :regenerate_recovery_code,
        args: [:current_password]
    end
  end
end
