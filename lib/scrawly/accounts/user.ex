defmodule Scrawly.Accounts.User do
  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  alias Scrawly.Accounts.User.Validations.NotReservedUsername

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
    defaults [:read]

    # Every action that accepts :username checks NotReservedUsername.
    update :update do
      primary? true
      accept [:username]
      validate NotReservedUsername
    end

    update :update_profile do
      accept [:username, :avatar_id, :avatar_color]
      validate NotReservedUsername
    end

    update :change_password do
      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      # Guests have no hashed_password, and PasswordValidation crashes on nil
      # (a FunctionClauseError whose report carried the typed passwords), so
      # these run first and the password check only on a valid changeset.
      validate attribute_equals(:is_guest, false) do
        message "register an account to set a password"
      end

      validate present(:hashed_password) do
        message "this account has no password"
      end

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password} do
        only_when_valid? true
      end

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}

      # Signs every browser out: revokes all stored tokens of the account (in
      # an after_action, inside the transaction). The log_out_everywhere
      # add-on's global password-change hook never fires here: its
      # `changing(:hashed_password)` condition is checked before
      # HashPasswordChange's before_action sets the hash. Callers that keep the
      # acting browser signed in mint a new token after the action returns.
      change AshAuthentication.AddOn.LogOutEverywhere.OnPasswordChange
    end

    create :register_with_password do
      # No upsert: a duplicate email must fail on the :unique_email identity.
      # An upsert would return the existing row with a fresh token (account takeover).
      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      accept [:email]

      change AshAuthentication.GenerateTokenChange
      change AshAuthentication.Strategy.Password.HashPasswordChange

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

      # Last, so its after_action puts the code on the final record.
      change Scrawly.Accounts.User.Changes.GenerateRecoveryCode

      metadata :token, :string do
        allow_nil? false
      end

      metadata :recovery_code, :string do
        allow_nil? false
      end
    end

    create :register_as_guest do
      accept []

      change fn changeset, _context ->
        suffix = :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)

        changeset
        |> Ash.Changeset.force_change_attribute(:email, "guest-#{suffix}@guest.scrawly.local")
        |> Ash.Changeset.force_change_attribute(:username, "guest-#{suffix}")
        |> Ash.Changeset.force_change_attribute(:is_guest, true)
        |> Ash.Changeset.after_action(fn _changeset, user ->
          {:ok, token, _claims} =
            AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "user"})

          {:ok, Ash.Resource.put_metadata(user, :token, token)}
        end)
      end

      metadata :token, :string do
        allow_nil? false
      end
    end

    update :upgrade_guest do
      require_atomic? false
      accept [:email]

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      change set_attribute(:is_guest, false)
      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}

      # Revokes the guest's stored tokens (after_action, in the transaction),
      # before the next change mints the account's new one.
      change AshAuthentication.AddOn.LogOutEverywhere.OnPasswordChange

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, user ->
          {:ok, token, _claims} =
            AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "user"})

          {:ok, Ash.Resource.put_metadata(user, :token, token)}
        end)
      end

      change Scrawly.Accounts.User.Changes.GenerateRecoveryCode

      metadata :token, :string do
        allow_nil? false
      end

      metadata :recovery_code, :string do
        allow_nil? false
      end
    end

    # Reset-only account recovery: the code can set a new password and nothing
    # else. Every failure path returns the same error after exactly one bcrypt
    # operation; see Actions.ResetPasswordWithRecoveryCode for the order.
    action :reset_password_with_recovery_code, :struct do
      constraints instance_of: __MODULE__
      transaction? true

      argument :email, :ci_string, allow_nil?: false, sensitive?: true

      argument :recovery_code, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 64]

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

      validate confirm(:password, :password_confirmation)

      run Scrawly.Accounts.User.Actions.ResetPasswordWithRecoveryCode
    end

    # Only called by :reset_password_with_recovery_code after the code matched.
    update :apply_recovery_reset do
      public? false
      require_atomic? false
      accept []

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

      validate confirm(:password, :password_confirmation)

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
      change Scrawly.Accounts.User.Changes.GenerateRecoveryCode

      metadata :recovery_code, :string do
        allow_nil? false
      end
    end

    update :regenerate_recovery_code do
      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      # Guests (and accounts created without a password) have no hashed_password,
      # and PasswordValidation would crash on nil, so these must run (and fail) first.
      validate attribute_equals(:is_guest, false) do
        message "register an account to get a recovery code"
      end

      validate present(:hashed_password) do
        message "this account has no password"
      end

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password} do
        only_when_valid? true
      end

      # Single use under concurrency: of two requests that loaded the same
      # code, only one stores a new one (the other gets a StaleRecord error).
      change Scrawly.Accounts.User.Changes.RequireUnchangedRecoveryCode
      change Scrawly.Accounts.User.Changes.GenerateRecoveryCode

      metadata :recovery_code, :string do
        allow_nil? false
      end
    end

    create :create do
      accept [:email, :username]
      primary? true
      validate NotReservedUsername
    end

    # The password strategy's sign-in action, declared here (instead of
    # generated) for the throttle. ThrottleSignIn goes after
    # SignInPreparation: see its moduledoc.
    read :sign_in_with_password do
      description "Attempt to sign in using an email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      prepare AshAuthentication.Strategy.Password.SignInPreparation
      prepare Scrawly.Accounts.User.Preparations.ThrottleSignIn

      metadata :token, :string do
        description "A JWT which the user can use to authenticate to the API."
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
    #
    # `score` is the player's score in their current room: 0 on joining,
    # reset to 0 for every player when a game starts (:reset_score), raised
    # by guess and drawer points during the game (:add_score), so after a
    # game it holds that game's final score until the next start; 0 again on
    # leaving.
    update :join_room do
      accept [:current_room_id, :username]
      validate NotReservedUsername
      change set_attribute(:player_state, :connected)
      change set_attribute(:score, 0)
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

    # A game starts: every player's room score goes back to 0 (see :join_room).
    update :reset_score do
      accept []
      change set_attribute(:score, 0)
    end

    # Adds a server-computed guess award in one UPDATE, so concurrent awards
    # can't overwrite each other.
    update :add_score do
      accept []

      argument :points, :integer do
        allow_nil? false
        constraints min: 0
      end

      change atomic_update(:score, expr(score + ^arg(:points)))
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
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
    end

    # bcrypt hash of the normalized recovery code (Scrawly.Accounts.RecoveryCode).
    attribute :hashed_recovery_code, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :recovery_code_generated_at, :utc_datetime_usec do
      allow_nil? true
    end

    # Player-specific attributes
    attribute :username, :string do
      public? true
      constraints min_length: 2, max_length: 20
    end

    attribute :is_guest, :boolean do
      default false
      allow_nil? false
      public? true
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
  end

  # The email's local part, trimmed and cut to 20 characters. One that is
  # shorter than 2 characters (`a@x.com`) or reserved (`system@...`) gets a
  # `_NNNN` suffix instead, so registration never fails on the username.
  defp generate_username(%{email: email}) do
    base =
      email
      |> to_string()
      |> String.split("@")
      |> List.first()
      |> String.trim()
      |> String.slice(0, 20)
      |> String.trim()

    if String.length(base) < 2 or NotReservedUsername.reserved?(base) do
      suffix = Integer.to_string(1000 + :rand.uniform(9000) - 1)
      String.slice(base, 0, 15) <> "_" <> suffix
    else
      base
    end
  end
end
