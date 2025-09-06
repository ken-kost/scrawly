defmodule Scrawly.Games.Game do
  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Games,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "games"
    repo Scrawly.Repo
  end

  actions do
    defaults [:read, :update, :destroy]

    create :create do
      accept [:room_id, :total_rounds, :current_word, :current_drawer_id]
      primary? true
    end

    create :start_game do
      accept [:room_id, :total_rounds]
      change set_attribute(:status, :in_progress)
      change set_attribute(:current_round, 1)
    end

    update :next_round do
      accept []
      change increment(:current_round, amount: 1)
    end

    update :end_game do
      accept []
      change set_attribute(:status, :completed)
    end

    update :start_round do
      accept [:current_drawer_id]
      require_atomic? false

      # Select a random word for this round
      change fn changeset, _context ->
        case Scrawly.Games.get_random_word() do
          {:ok, word} ->
            Ash.Changeset.change_attribute(changeset, :current_word, word)

          {:error, _reason} ->
            Ash.Changeset.add_error(changeset,
              field: :current_word,
              message: "No words available"
            )
        end
      end
    end

    update :select_next_drawer do
      accept []
      require_atomic? false

      argument :player_queue, {:array, :uuid} do
        allow_nil? false
        description "Ordered list of player IDs for drawer rotation"
      end

      # Select next drawer from the queue
      change fn changeset, _context ->
        game = changeset.data
        player_queue = Ash.Changeset.get_argument(changeset, :player_queue)

        # Find current drawer index and select next one
        current_drawer_id = game.current_drawer_id
        current_index = Enum.find_index(player_queue, &(&1 == current_drawer_id))

        next_index =
          case current_index do
            # First drawer
            nil -> 0
            # Next in rotation
            index -> rem(index + 1, length(player_queue))
          end

        next_drawer_id = Enum.at(player_queue, next_index)
        Ash.Changeset.change_attribute(changeset, :current_drawer_id, next_drawer_id)
      end
    end

    update :complete_round do
      accept []

      # Clear current word and drawer for round transition
      change set_attribute(:current_word, nil)
      change set_attribute(:current_drawer_id, nil)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      default :in_progress
      public? true
      constraints one_of: [:in_progress, :completed, :cancelled]
    end

    attribute :current_round, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1
    end

    attribute :total_rounds, :integer do
      allow_nil? false
      default 5
      public? true
      constraints min: 1, max: 10
    end

    attribute :current_word, :string do
      public? true
    end

    attribute :current_drawer_id, :uuid do
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :room, Scrawly.Games.Room do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :current_drawer, Scrawly.Accounts.User do
      source_attribute :current_drawer_id
      destination_attribute :id
    end
  end
end
