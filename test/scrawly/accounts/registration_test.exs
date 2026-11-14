defmodule Scrawly.Accounts.RegistrationTest do
  use Scrawly.DataCase, async: true

  alias Scrawly.Accounts
  alias Scrawly.Accounts.User

  defp unique_email, do: "reg-#{System.unique_integer([:positive])}@example.com"

  defp strategy_register(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)
    AshAuthentication.Strategy.action(strategy, :register, %{email: email, password: password})
  end

  defp session_keys(server) do
    server |> Hologram.Server.get_session_ops() |> Map.keys() |> Enum.map(&to_string/1)
  end

  describe "register_with_password" do
    test "first registration returns a token and generates a username" do
      email = unique_email()

      {:ok, user} = Accounts.register_with_password(email, "password123")

      assert is_binary(user.__metadata__[:token])
      assert is_binary(user.username)
      assert user.is_guest == false
    end

    test "an existing email is rejected and the original account is untouched" do
      email = unique_email()
      {:ok, victim} = Accounts.register_with_password(email, "victim-password-1")

      assert {:error, _} = Accounts.register_with_password(email, "attacker-password-2")

      assert {:error, _} =
               Accounts.register_with_password(String.upcase(email), "attacker-password-2")

      reloaded = Ash.get!(User, victim.id, authorize?: false)
      assert reloaded.hashed_password == victim.hashed_password
      assert to_string(reloaded.email) == email

      assert {:ok, _} = Accounts.sign_in_with_password(email, "victim-password-1")
      assert {:error, _} = Accounts.sign_in_with_password(email, "attacker-password-2")
    end

    test "the password strategy's register action also rejects an existing email" do
      email = unique_email()
      {:ok, _victim} = Accounts.register_with_password(email, "victim-password-1")

      assert {:error, _} = strategy_register(email, "attacker-password-2")
    end

    test "a guest's email cannot be registered over" do
      guest = Accounts.register_as_guest!()

      assert {:error, _} = Accounts.register_with_password(to_string(guest.email), "password123")
    end

    test "passwords shorter than 8 characters are rejected" do
      assert {:error, _} = Accounts.register_with_password(unique_email(), "short")
    end
  end

  describe "register commands with an existing email" do
    setup do
      email = unique_email()
      {:ok, victim} = Accounts.register_with_password(email, "victim-password-1")
      %{email: email, victim: victim}
    end

    test "HomePage :register writes no session and reports failure", %{email: email} do
      server = %Hologram.Server{session: %{}}

      result =
        ScrawlyWeb.Pages.HomePage.command(
          :register,
          %{email: email, password: "attacker-password-2"},
          server
        )

      assert result.next_action.name == :login_failed
      refute "user_id" in session_keys(result)
      refute "user_token" in session_keys(result)
    end

    test "AppLayout :register writes no session and reports failure", %{email: email} do
      server = %Hologram.Server{session: %{}}

      result =
        ScrawlyWeb.Layouts.AppLayout.command(
          :register,
          %{email: email, password: "attacker-password-2"},
          server
        )

      assert result.next_action.name == :auth_error
      refute "user_id" in session_keys(result)
      refute "user_token" in session_keys(result)
    end
  end
end
