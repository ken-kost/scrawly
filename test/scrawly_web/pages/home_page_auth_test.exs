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
      assert result.state.is_guest == false
    end

    test "loads authenticated user data from session" do
      # Create a test user
      {:ok, user} =
        Ash.create(User, %{email: "test-#{System.unique_integer([:positive])}@example.com"},
          authorize?: false
        )

      # A real stored session token, run through the page middleware.
      server = Scrawly.SessionTestHelpers.signed_in_server(user)

      component = %Hologram.Component{}

      # Initialize the page
      result = HomePage.init(%{}, component, server)

      # Should have user data in state
      assert result.state.authenticated == true
      assert result.state.is_guest == false
    end

    test "a session user_id without a valid token is signed out" do
      {:ok, user} =
        Ash.create(User, %{email: "test-#{System.unique_integer([:positive])}@example.com"},
          authorize?: false
        )

      server =
        ScrawlyWeb.Middleware.LoadCurrentUser.call(
          %Hologram.Server{session: %{"user_id" => user.id}},
          []
        )

      result = HomePage.init(%{}, %Hologram.Component{}, server)

      assert result.state.authenticated == false
      assert result.state.is_guest == false
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
