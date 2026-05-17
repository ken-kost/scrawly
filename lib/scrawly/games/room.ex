defmodule Scrawly.Games.Room do
  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Games,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  require AshAi.Actions

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
      accept [
        :name,
        :max_players,
        :creator_id,
        :word_count,
        :word_source,
        :prompt,
        :round_duration,
        :round_multiplier,
        :ai_tone
      ]

      primary? true

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :code, generate_room_code())
      end
    end

    update :join_room do
      accept []
      require_atomic? false

      argument :player_id, :uuid do
        allow_nil? false
        description "ID of the player joining the room"
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

      # Validate room capacity and creator presence
      validate fn changeset, _context ->
        room = changeset.data
        room_with_players = Ash.load!(room, :players)
        current_player_count = length(room_with_players.players)
        player_id = Ash.Changeset.get_argument(changeset, :player_id)

        cond do
          current_player_count >= room.max_players ->
            {:error, field: :max_players, message: "Room is at maximum capacity"}

          # Creator can always join their own room
          player_id == room.creator_id ->
            :ok

          # For non-creators, verify creator is present
          not Enum.any?(room_with_players.players, &(&1.id == room.creator_id)) ->
            {:error, field: :creator_id, message: "Cannot join room when creator is not present"}

          true ->
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

    update :post_game do
      accept []
      change set_attribute(:status, :post_game)
    end

    update :return_to_lobby do
      accept []
      change set_attribute(:status, :lobby)
      change set_attribute(:current_round, 0)
    end

    update :auto_start_if_ready do
      accept []
      require_atomic? false

      validate fn changeset, _context ->
        room = changeset.data

        if room.status != :lobby do
          {:error, field: :status, message: "Can only auto-start rooms in lobby state"}
        else
          :ok
        end
      end

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

      change fn changeset, _context ->
        room = changeset.data
        room_with_players = Ash.load!(room, :players)
        player_id = Ash.Changeset.get_argument(changeset, :player_id)
        remaining_players = Enum.reject(room_with_players.players, &(&1.id == player_id))
        remaining_count = length(remaining_players)

        cond do
          player_id == room.creator_id ->
            changeset
            |> Ash.Changeset.change_attribute(:status, :ended)

          remaining_count == 0 ->
            changeset
            |> Ash.Changeset.change_attribute(:status, :lobby)
            |> Ash.Changeset.change_attribute(:current_round, 0)

          remaining_count == 1 && room.status == :playing ->
            changeset
            |> Ash.Changeset.change_attribute(:status, :ended)

          true ->
            changeset
        end
      end
    end

    # AI word generation — prompt-backed action via ash_ai
    action :generate_ai_words, {:array, :string} do
      description """
      Generates a list of drawing words/phrases based on a theme prompt.
      Each entry matches the specified word_count constraint (1, 2, or 3 words).
      Words should be concrete, drawable things suitable for a drawing game.
      """

      argument :prompt, :string do
        allow_nil? false

        description "The theme or category for word generation, e.g. 'ocean animals' or 'things in a kitchen'"
      end

      argument :word_count, :integer do
        allow_nil? false
        description "Number of words per entry: 1, 2, or 3"
      end

      argument :num_words, :integer do
        allow_nil? false
        default 20
        description "How many words/phrases to generate"
      end

      argument :tone, :string do
        allow_nil? false
        default "fun"
        description "The tone/style of words: fun, creative, or weird"
      end

      run AshAi.Actions.prompt(
            LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"}),
            prompt: """
            Generate exactly <%= @input.arguments.num_words %> unique drawing game words/phrases based on this theme: "<%= @input.arguments.prompt %>".

            RULES:
            - Each entry MUST be exactly <%= @input.arguments.word_count %> word(s) long.
            - Words generated based on a prompt.
            - Keep them <%= @input.arguments.tone %>.
            - No duplicates. Every single entry must be unique.
            - Return exactly <%= @input.arguments.num_words %> entries, no more, no less.
            """,
            tools: false
          )
    end
  end

  pub_sub do
    module Scrawly.PubSub
    prefix "room"

    publish :join_room, ["player_joined", :id]
    publish :start_game, ["game_started", :id]
    publish :end_game, ["game_ended", :id]
    publish_all :update, ["room_updated", :id]
  end

  preparations do
    prepare build(load: :players)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :code, :string do
      allow_nil? true
      public? true
      constraints min_length: 4, max_length: 12
    end

    attribute :status, :atom do
      allow_nil? false
      default :lobby
      public? true
      constraints one_of: [:lobby, :playing, :post_game, :ended]
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

    attribute :creator_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :word_count, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1, max: 3
    end

    attribute :word_source, :atom do
      allow_nil? false
      default :local
      public? true
      constraints one_of: [:local, :ai]
    end

    attribute :prompt, :string do
      public? true
    end

    attribute :round_duration, :integer do
      allow_nil? false
      default 60
      public? true
      constraints min: 60, max: 300
    end

    attribute :round_multiplier, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1, max: 5
    end

    attribute :ai_tone, :atom do
      allow_nil? false
      default :fun
      public? true
      constraints one_of: [:fun, :creative, :weird]
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :creator, Scrawly.Accounts.User do
      source_attribute :creator_id
      destination_attribute :id
      define_attribute? false
    end

    has_many :players, Scrawly.Accounts.User do
      destination_attribute :current_room_id
    end

    has_many :games, Scrawly.Games.Game
  end

  identities do
    identity :unique_code, [:code]
  end

  defp generate_room_code do
    :crypto.strong_rand_bytes(4)
    |> Base.encode32(case: :upper, padding: false)
    |> String.slice(0, 6)
  end
end
