defmodule Scrawly.Accounts.User do
  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Scrawly.Accounts.Token
      signing_secret Scrawly.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      magic_link do
        identity_field :email
        registration_enabled? true
        require_interaction? true

        sender Scrawly.Accounts.User.Senders.SendMagicLinkEmail
      end
    end
  end

  postgres do
    table "users"
    repo Scrawly.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:email]
      change Scrawly.Accounts.Changes.GenerateUsernameFromEmail
      primary? true
      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get? true

      argument :email, :ci_string do
        allow_nil? false
      end

      filter expr(email == ^arg(:email))
    end

    create :sign_in_with_magic_link do
      description "Sign in or register a user with magic link."

      argument :token, :string do
        description "The token from the magic link that was sent to the user"
        allow_nil? false
      end

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]

      # Uses the information from the token to create or sign in the user
      change AshAuthentication.Strategy.MagicLink.SignInChange
      # Generate username from email for new users
      change Scrawly.Accounts.Changes.GenerateUsernameFromEmail

      metadata :token, :string do
        allow_nil? false
      end
    end

    action :request_magic_link do
      argument :email, :ci_string do
        allow_nil? false
      end

      run AshAuthentication.Strategy.MagicLink.Request
    end

    # Player-specific actions
    update :join_room do
      accept [:current_room_id, :username]
      change set_attribute(:player_state, :connected)
    end

    update :leave_room do
      accept []
      change set_attribute(:current_room_id, nil)
      change set_attribute(:player_state, :disconnected)
      change set_attribute(:score, 0)
    end

    update :update_score do
      accept [:score]
    end

    update :set_player_state do
      accept [:player_state]
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    # Player-specific attributes
    attribute :username, :string do
      public? true
      constraints min_length: 2, max_length: 20
    end

    attribute :score, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :player_state, :atom do
      default :disconnected
      public? true
      constraints one_of: [:connected, :drawing, :guessing, :disconnected]
    end

    attribute :current_room_id, :uuid do
      public? true
    end
  end

  relationships do
    belongs_to :current_room, Scrawly.Games.Room do
      source_attribute :current_room_id
      destination_attribute :id
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
