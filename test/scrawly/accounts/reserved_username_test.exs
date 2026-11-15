defmodule Scrawly.Accounts.ReservedUsernameTest do
  @moduledoc """
  "System" speaks for the game in chat, so no account may take that name, in
  any action that accepts `:username`. See `User.Validations.NotReservedUsername`.
  """
  use Scrawly.DataCase, async: true

  require Ash.Query

  alias Scrawly.Accounts
  alias Scrawly.Accounts.User
  alias Scrawly.Accounts.User.Validations.NotReservedUsername

  @reserved_variants ["System", "system", " SYSTEM ", "sYsTeM"]

  defp n, do: System.unique_integer([:positive])

  defp user!(username \\ nil) do
    username = username || "TEST#{n()}"
    Ash.create!(User, %{email: "reserved-#{n()}@example.com", username: username})
  end

  # A row that predates the rule (bypasses actions and validations).
  defp legacy_system_user! do
    Ash.Seed.seed!(User, %{email: "legacy-#{n()}@example.com", username: "System"})
  end

  defp reload!(user), do: Ash.get!(User, user.id, authorize?: false)

  defp username_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidAttribute{field: :username}, &1))
  end

  describe "reserved?/1" do
    test "matches \"system\" case-insensitively after trimming" do
      for name <- @reserved_variants, do: assert(NotReservedUsername.reserved?(name))
    end

    test "only matches the whole name" do
      for name <- ["systemfan", "the system", "sys tem", "Systems", nil, 42] do
        refute NotReservedUsername.reserved?(name)
      end
    end
  end

  describe "update_profile" do
    test "rejects System, system and \" SYSTEM \" and keeps the old name" do
      user = user!()

      for name <- @reserved_variants do
        assert {:error, error} = Accounts.update_profile(user, %{username: name})
        assert username_error?(error), "#{inspect(name)} was not rejected on :username"
      end

      assert reload!(user).username == user.username
    end

    test "accepts names that only contain the word" do
      user = user!()

      for name <- ["systemfan", "the system", "Systems"] do
        assert {:ok, %{username: ^name}} = Accounts.update_profile(user, %{username: name})
      end
    end

    test "passes when the username is not changing, even for a legacy \"System\" row" do
      legacy = legacy_system_user!()

      assert {:ok, updated} =
               Accounts.update_profile(legacy, %{username: "System", avatar_color: "5"})

      assert updated.username == "System"
      assert updated.avatar_color == "5"
    end

    test "passes when the username is cleared" do
      user = user!()
      assert {:ok, %{username: nil}} = Accounts.update_profile(user, %{username: nil})
    end
  end

  describe "the other actions that accept :username" do
    test "the primary :update rejects a reserved name" do
      user = user!()

      for name <- @reserved_variants do
        assert {:error, error} =
                 user |> Ash.Changeset.for_update(:update, %{username: name}) |> Ash.update()

        assert username_error?(error)
      end

      assert {:ok, %{username: "plain"}} =
               user |> Ash.Changeset.for_update(:update, %{username: "plain"}) |> Ash.update()
    end

    test ":create rejects a reserved name" do
      for name <- @reserved_variants do
        assert {:error, error} =
                 Ash.create(User, %{email: "c-#{n()}@example.com", username: name})

        assert username_error?(error)
      end
    end

    test ":join_room rejects a reserved name" do
      user = user!()

      assert {:error, error} =
               user
               |> Ash.Changeset.for_update(:join_room, %{current_room_id: nil, username: "SYSTEM"})
               |> Ash.update()

      assert username_error?(error)
      assert reload!(user).username == user.username
    end
  end

  describe "atomic updates" do
    test "a literal reserved name is rejected in a bulk atomic update" do
      user = user!()

      result =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.bulk_update(:update_profile, %{username: "System"},
          strategy: :atomic,
          return_errors?: true
        )

      assert result.status == :error
      assert Enum.any?(result.errors, &username_error?/1)
      assert reload!(user).username == user.username
    end

    test "ordinary names and a legacy row's unchanged name pass in a bulk atomic update" do
      user = user!()
      legacy = legacy_system_user!()

      for {target, params} <- [
            {user, %{username: "plain"}},
            {legacy, %{username: "System", avatar_color: "7"}}
          ] do
        result =
          User
          |> Ash.Query.filter(id == ^target.id)
          |> Ash.bulk_update(:update_profile, params, strategy: :atomic, return_errors?: true)

        assert result.status == :success, inspect(result.errors)
      end

      assert reload!(user).username == "plain"
      assert %{username: "System", avatar_color: "7"} = reload!(legacy)
    end
  end

  # Ash's :string type trims input before any validation runs, so padded
  # names can't reach the validation through action inputs; this drives
  # validate/3 with a changeset that holds one.
  describe "validate/3" do
    test "rejects leading or trailing whitespace" do
      user = user!()
      context = %Ash.Resource.Validation.Context{}

      for name <- [" bob", "bob ", "\tbob"] do
        changeset = %{Ash.Changeset.new(user) | attributes: %{username: name}}

        assert {:error, %Ash.Error.Changes.InvalidAttribute{field: :username}} =
                 NotReservedUsername.validate(changeset, [], context)
      end

      changeset = %{Ash.Changeset.new(user) | attributes: %{username: "bob"}}
      assert NotReservedUsername.validate(changeset, [], context) == :ok
      assert NotReservedUsername.validate(Ash.Changeset.new(user), [], context) == :ok
    end
  end

  describe "registration" do
    test "system@example.com registers with a non-reserved generated username" do
      assert {:ok, user} = Accounts.register_with_password("system@example.com", "password123")

      refute NotReservedUsername.reserved?(user.username)
      assert user.username =~ ~r/\Asystem_\d{4}\z/
    end

    test "a one-character local part still registers, with a padded username" do
      assert {:ok, user} = Accounts.register_with_password("a@x#{n()}.com", "password123")

      assert String.length(user.username) >= 2
      assert user.username =~ ~r/\Aa_\d{4}\z/
    end

    test "an ordinary local part is used as is" do
      assert {:ok, user} =
               Accounts.register_with_password("jane.doe@x#{n()}.com", "password123")

      assert user.username == "jane.doe"
    end
  end
end
