defmodule Scrawly.Games do
  use Ash.Domain,
    otp_app: :scrawly,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Scrawly.Games.Room
    resource Scrawly.Games.Game
  end
end
