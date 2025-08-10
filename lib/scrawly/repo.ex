defmodule Scrawly.Repo do
  use Ecto.Repo,
    otp_app: :scrawly,
    adapter: Ecto.Adapters.Postgres
end
