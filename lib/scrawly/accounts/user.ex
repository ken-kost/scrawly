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
      password :password do
        identity_field :email
        hashed_password_field :hashed_password
        confirmation_required? false
      end
    end
  end

  postgres do
    table "users"
    repo Scrawly.Repo
  end

  actions do
    defaults [:read, update: [:username]]

    update :update_profile do
      accept [:username, :avatar_id, :avatar_color]
    end

    update :change_password do
      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false
      argument :password, :string, sensitive?: true, allow_nil?: false, constraints: [min_length: 8]
      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    create :register_with_password do
      argument :password, :string, allow_nil?: false, sensitive?: true

      accept [:email]

      change AshAuthentication.GenerateTokenChange
      change AshAuthentication.Strategy.Password.HashPasswordChange

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, user ->
          if is_nil(user.username) do
            user
            |> Ash.Changeset.for_update(:update, %{username: generate_username(user)})
            |> Ash.update()
          else
            {:ok, user}
          end
        end)
      end

      metadata :token, :string do
        allow_nil? false
      end
    end

    create :create do
      accept [:email, :username]
      primary? true
    end

    create :register_with_device_id do
      description "Find-or-create a guest user by stable per-device UUID (mob auto-login)."

      argument :device_id, :uuid, allow_nil?: false

      upsert? true
      upsert_identity :unique_device_id
      upsert_fields [:device_id]

      change set_attribute(:device_id, arg(:device_id))

      change fn changeset, _ctx ->
        uuid = Ash.Changeset.get_argument(changeset, :device_id)
        short = uuid |> to_string() |> String.slice(0, 8)

        changeset
        |> Ash.Changeset.force_change_attribute(:email, "device-#{uuid}@scrawly.local")
        |> Ash.Changeset.force_change_attribute(:username, "guest-#{short}")
      end

      change fn changeset, _ctx ->
        Ash.Changeset.after_action(changeset, fn _changeset, user ->
          {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
          {:ok, Ash.Resource.put_metadata(user, :token, token)}
        end)
      end

      metadata :token, :string do
        allow_nil? false
      end
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

    update :update_dark_mode do
      accept [:dark_mode]
    end

    update :update_accent_color do
      accept [:accent_color]
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
      allow_nil? true
      public? true
    end

    attribute :device_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
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

    attribute :dark_mode, :boolean do
      default false
      allow_nil? false
      public? true
    end

    attribute :accent_color, :atom do
      default :purple
      allow_nil? false
      public? true
      constraints one_of: [:purple, :yellow, :orange]
    end

    attribute :avatar_id, :string do
      default "a-mushroom"
      allow_nil? false
      public? true
    end

    attribute :avatar_color, :string do
      default "3"
      allow_nil? false
      public? true
      constraints match: ~r/^([1-9]|1[0-9]|2[0-4])$/
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
    identity :unique_device_id, [:device_id]
  end

  defp generate_username(%{email: email}) do
    email
    |> to_string()
    |> String.split("@")
    |> List.first()
  end
end
