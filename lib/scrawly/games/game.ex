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

    read :get_by_room do
      argument :room_id, :uuid do
        allow_nil? false
      end

      filter expr(room_id == ^arg(:room_id))
      prepare build(sort: [inserted_at: :desc], limit: 1)
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

    update :save_round_details do
      accept [:round_details]
    end

    update :start_round do
      accept [:current_drawer_id]
      require_atomic? false

      argument :used_words, {:array, :string} do
        default []
        description "Previously used words to exclude from selection"
      end

      argument :word_count, :integer do
        default 1
        description "Number of words per entry (1, 2, or 3)"
      end

      argument :override_word, :string do
        description "If provided, use this word instead of selecting from DB (for AI-generated words)"
      end

      # Select a random word for this round, or use the override word
      change fn changeset, _context ->
        override = Ash.Changeset.get_argument(changeset, :override_word)

        if override do
          Ash.Changeset.change_attribute(changeset, :current_word, override)
        else
          used = Ash.Changeset.get_argument(changeset, :used_words) || []
          word_count = Ash.Changeset.get_argument(changeset, :word_count) || 1

          case Scrawly.Games.get_random_word(exclude: used, word_count: word_count) do
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

    read :for_room do
      argument :room_id, :uuid, allow_nil?: false
      filter expr(room_id == ^arg(:room_id) and status == :completed)
      prepare build(sort: [created_at: :desc], limit: 10)
    end

    update :complete_round do
      accept []

      # Clear current word for round transition.
      # Keep current_drawer_id so select_next_drawer can find the previous
      # drawer and correctly rotate to the next player.
      change set_attribute(:current_word, nil)
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
      constraints min: 1, max: 12
    end

    attribute :current_word, :string do
      public? true
    end

    attribute :current_drawer_id, :uuid do
      public? true
    end

    attribute :round_details, {:array, :map} do
      public? true
      default []
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
