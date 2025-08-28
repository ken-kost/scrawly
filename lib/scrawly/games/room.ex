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

      change set_attribute(:status, :lobby)
      change set_attribute(:current_round, 0)

      change fn changeset, _context ->
        code = generate_room_code()
        Ash.Changeset.force_change_attribute(changeset, :code, code)
      end
    end

    update :join_room do
      accept []
      require_atomic? false

      argument :player_id, :uuid do
        allow_nil? false
        description "ID of the player joining the room"
      end

      # Validate room capacity
      validate fn changeset, _context ->
        room = changeset.data

        # Load current players to count them
        room_with_players = Ash.load!(room, :players)
        current_player_count = length(room_with_players.players)

        if current_player_count >= room.max_players do
          {:error, field: :max_players, message: "Room is at maximum capacity"}
        else
          :ok
        end
      end

      # Validate room is in lobby state
      validate fn changeset, _context ->
        room = changeset.data

        if room.status != :lobby do
          {:error, field: :status, message: "Cannot join room that is not in lobby"}
        else
          :ok
        end
      end
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

    update :auto_start_if_ready do
      accept []
      require_atomic? false

      # Validate room is in lobby state
      validate fn changeset, _context ->
        room = changeset.data

        if room.status != :lobby do
          {:error, field: :status, message: "Can only auto-start rooms in lobby state"}
        else
          :ok
        end
      end

      # Check if we have minimum players and auto-start
      change fn changeset, _context ->
        room = changeset.data
        room_with_players = Ash.load!(room, :players)
        current_player_count = length(room_with_players.players)

        if current_player_count >= 2 do
          changeset
          |> Ash.Changeset.change_attribute(:status, :playing)
          |> Ash.Changeset.change_attribute(:current_round, 1)
        else
          changeset
        end
      end
    end

    update :handle_player_disconnect do
      accept []
      require_atomic? false

      argument :player_id, :uuid do
        allow_nil? false
        description "ID of the player disconnecting from the room"
      end

      # If room becomes empty or has insufficient players, reset to lobby
      change fn changeset, _context ->
        room = changeset.data
        room_with_players = Ash.load!(room, :players)

        # Filter out the disconnecting player
        player_id = Ash.Changeset.get_argument(changeset, :player_id)
        remaining_players = Enum.reject(room_with_players.players, &(&1.id == player_id))
        remaining_count = length(remaining_players)

        cond do
          remaining_count == 0 ->
            # Room is empty, reset to lobby
            changeset
            |> Ash.Changeset.change_attribute(:status, :lobby)
            |> Ash.Changeset.change_attribute(:current_round, 0)

          remaining_count == 1 && room.status == :playing ->
            # Only one player left during game, end the game
            changeset
            |> Ash.Changeset.change_attribute(:status, :ended)

          true ->
            # Sufficient players remain, no state change needed
            changeset
        end
      end
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
