defmodule Scrawly.Games.GameResult do
  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Games,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "game_results"
    repo Scrawly.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:player_id, :game_id, :room_id, :score, :player_username]
      primary? true
    end

    read :for_player do
      argument :player_id, :uuid, allow_nil?: false
      filter expr(player_id == ^arg(:player_id))
      prepare build(sort: [created_at: :desc])
    end

    read :for_game do
      argument :game_id, :uuid, allow_nil?: false
      filter expr(game_id == ^arg(:game_id))
      prepare build(sort: [score: :desc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :player_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :game_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :room_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :score, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :player_username, :string do
      public? true
    end

    create_timestamp :created_at
  end

  relationships do
    belongs_to :player, Scrawly.Accounts.User do
      source_attribute :player_id
      destination_attribute :id
      define_attribute? false
    end

    belongs_to :game, Scrawly.Games.Game do
      source_attribute :game_id
      destination_attribute :id
      define_attribute? false
    end

    belongs_to :room, Scrawly.Games.Room do
      source_attribute :room_id
      destination_attribute :id
      define_attribute? false
    end
  end
end
