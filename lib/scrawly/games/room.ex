defmodule Scrawly.Games.Room do
  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Games,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "rooms"
    repo Scrawly.Repo
  end

  actions do
    defaults [:read, :destroy]

    update :update do
      primary? true
      accept [:max_players, :status, :current_round]
    end

    create :create do
      accept [:max_players, :code]
      primary? true

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :code) do
          nil ->
            code = generate_room_code()
            Ash.Changeset.force_change_attribute(changeset, :code, code)

          _ ->
            changeset
        end
      end
    end

    create :create_room do
      accept [:max_players]

      # Generate a unique room code (will implement custom change later)
      change set_attribute(:status, :lobby)
      change set_attribute(:current_round, 0)
    end

    update :join_room do
      require_atomic? false
    end

    update :start_game do
      accept []
      change set_attribute(:status, :playing)
      change set_attribute(:current_round, 1)
    end

    update :end_game do
      accept []
      change set_attribute(:status, :ended)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :code, :string do
      allow_nil? true
      public? true
      constraints min_length: 4, max_length: 12
    end

    attribute :status, :atom do
      allow_nil? false
      default :lobby
      public? true
      constraints one_of: [:lobby, :playing, :ended]
    end

    attribute :max_players, :integer do
      allow_nil? false
      default 12
      public? true
      constraints min: 2, max: 12
    end

    attribute :current_round, :integer do
      allow_nil? false
      default 0
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :players, Scrawly.Accounts.User do
      destination_attribute :current_room_id
    end

    has_many :games, Scrawly.Games.Game
  end

  identities do
    identity :unique_code, [:code]
  end

  # Helper function to generate unique room codes
  defp generate_room_code do
    :crypto.strong_rand_bytes(4)
    |> Base.encode32(case: :upper, padding: false)
    |> String.slice(0, 6)
  end
end
