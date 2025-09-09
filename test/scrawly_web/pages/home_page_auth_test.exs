defmodule ScrawlyWeb.Pages.HomePageAuthTest do
  use ExUnit.Case, async: true
  use ScrawlyWeb.ConnCase

  alias ScrawlyWeb.Pages.HomePage
  alias Scrawly.Accounts.User

  describe "authentication integration" do
    test "redirects unauthenticated user to sign-in page" do
      # Create a mock component and server without authentication
      component = %Hologram.Component{}
      server = %Hologram.Server{session: %{}}

      # This should redirect to sign-in page when no user is authenticated
      result = HomePage.init(%{}, component, server)

      # Should redirect to sign-in (this will fail initially)
      assert result.page == ScrawlyWeb.Pages.SignInPage
    end

    test "loads authenticated user data from session" do
      # Create a test user
      {:ok, user} =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "test@example.com",
          username: "test123"
        })
        |> Ash.create()

      # Mock server with authenticated user in session
      server = %Hologram.Server{
        session: %{
          "current_user" => user
        }
      }

      component = %Hologram.Component{}

      # Initialize the page
      result = HomePage.init(%{}, component, server)

      # Should have user data in state
      assert result.state.current_user_id == user.id
      assert result.state.current_user_email == user.email
      assert result.state.current_user_username == user.username
    end

    test "auto-generates username from email during registration" do
      email = "john.doe@example.com"

      # This should create a username like "john.doe123" where 123 is a unique integer
      {:ok, user} =
        User
        |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{
          token: "mock-token"
        })
        |> Ash.create()

      # Username should be generated from email prefix
      assert String.starts_with?(user.username, "john.doe")
      assert String.length(user.username) > String.length("john.doe")
    end
  end
end
