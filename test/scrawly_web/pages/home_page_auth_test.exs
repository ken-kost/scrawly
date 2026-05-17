defmodule ScrawlyWeb.Pages.HomePageAuthTest do
  use ExUnit.Case, async: false

  alias ScrawlyWeb.Pages.HomePage
  alias Scrawly.Accounts.User

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
  end

  describe "authentication integration" do
    test "unauthenticated user sees unauthenticated state" do
      # Create a mock component and server without authentication
      component = %Hologram.Component{}
      server = %Hologram.Server{session: %{}}

      # This should set authenticated to false when no user is in session
      result = HomePage.init(%{}, component, server)

      assert result.state.authenticated == false
      assert result.state.current_user == nil
    end

    test "loads authenticated user data from session" do
      # Create a test user
      {:ok, user} =
        Ash.create(User, %{email: "test-#{System.unique_integer([:positive])}@example.com"},
          authorize?: false
        )

      # Mock server with authenticated user in session
      server = %Hologram.Server{
        session: %{
          "user_id" => user.id
        }
      }

      component = %Hologram.Component{}

      # Initialize the page
      result = HomePage.init(%{}, component, server)

      # Should have user data in state
      assert result.state.authenticated == true
      assert result.state.current_user.id == user.id
    end

    test "auto-generates username from email during registration" do
      email = "john.doe-#{System.unique_integer([:positive])}@example.com"

      strategy = AshAuthentication.Info.strategy!(User, :password)

      {:ok, user} =
        AshAuthentication.Strategy.action(strategy, :register, %{
          email: email,
          password: "password123"
        })

      # Username should be generated from email prefix
      assert user.username != nil
      assert is_binary(user.username)
      assert String.starts_with?(user.username, "john.doe")
    end
  end
end
