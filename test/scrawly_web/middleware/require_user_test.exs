defmodule ScrawlyWeb.Middleware.RequireUserTest do
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers, only: [create_user: 0]
  import Scrawly.SessionTestHelpers

  alias AshAuthentication.TokenResource
  alias Hologram.Server
  alias Scrawly.Accounts
  alias ScrawlyWeb.Middleware.RequireUser
  alias ScrawlyWeb.Pages.ProfilePage

  @moduletag :capture_log

  describe "call/2" do
    test "without a user it redirects to the home page" do
      for server <- [%Server{}, %Server{stash: %{current_user_id: nil, current_user: nil}}] do
        result = RequireUser.call(server, [])

        assert result.status == 302
        assert result.response_headers["location"] == "/"
      end
    end

    test "with the stashed user it passes" do
      user = create_user()
      server = signed_in_server(user)

      assert RequireUser.call(server, []) == server
    end
  end

  describe "ProfilePage's middleware chain" do
    test "is LoadCurrentUser (load: :user) and then RequireUser" do
      assert [{load, []}, {require, []}] = ProfilePage.__middleware__()
      assert load == (&ScrawlyWeb.Middleware.LoadCurrentUser.call/2)
      assert require == (&RequireUser.call/2)
    end

    test "a signed-out request gets a 302 to / and never reaches init" do
      result = run_page_middleware(ProfilePage, %Server{session: %{}})

      assert result.status == 302
      assert result.response_headers["location"] == "/"
    end

    test "a revoked session gets the 302 and loses its session keys" do
      user = create_user()
      token = mint_token!(user)
      :ok = TokenResource.Actions.revoke(Accounts.Token, token)

      result = run_page_middleware(ProfilePage, session_server(user, token))

      assert result.status == 302
      assert result.response_headers["location"] == "/"
      assert "user_id" in session_deletes(result)
      assert "user_token" in session_deletes(result)
    end

    test "a valid session reaches init with the user stashed" do
      user = create_user()
      result = run_page_middleware(ProfilePage, session_server(user))

      assert result.status == nil
      assert result.stash.current_user.id == user.id

      state = ProfilePage.init(%{}, %Hologram.Component{}, result).state
      assert state.user_id == user.id
      assert state.email == to_string(user.email)
      assert Scrawly.RoomTestHelpers.struct_free?(state)
    end
  end
end
