defmodule ScrawlyWeb.AuthControllerTest do
  @moduledoc """
  GET /guest creates a guest only for a session without a valid account. The
  session cookie is SameSite=Lax, so a link to /guest must not switch a
  signed-in user to a new guest, and repeat visits must not create rows.
  """
  use ScrawlyWeb.ConnCase, async: true

  import Scrawly.RoomTestHelpers, only: [create_user: 0]
  import Scrawly.SessionTestHelpers, only: [mint_token!: 1, token_valid?: 2]

  alias AshAuthentication.TokenResource
  alias Scrawly.Accounts
  alias ScrawlyWeb.Middleware.LoadCurrentUser

  defp user_count, do: Accounts.User |> Ash.count!(authorize?: false)

  describe "password sign-in (AuthController.success/4)" do
    test "leaves a session the pages accept", %{conn: conn} do
      email = "authctl-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.register_with_password(email, "password123")

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/auth/user/password/sign_in", %{
          "user" => %{"email" => email, "password" => "password123"}
        })

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
      assert token_valid?(user, get_session(conn, :user_token))

      server = LoadCurrentUser.call(%Hologram.Server{session: get_session(conn)}, [])
      assert server.user_id == user.id
    end
  end

  describe "GET /guest" do
    test "keeps a valid registered session user and creates nothing", %{conn: conn} do
      user = create_user()
      token = mint_token!(user)
      before = user_count()

      conn =
        conn
        |> init_test_session(%{user_id: user.id, user_token: token})
        |> get(~p"/guest?return_to=/game/abc")

      assert redirected_to(conn) == "/game/abc"
      assert user_count() == before
      assert get_session(conn, :user_id) == user.id
      assert get_session(conn, :user_token) == token
    end

    test "keeps an existing guest on a repeat visit", %{conn: conn} do
      guest = Accounts.register_as_guest!()
      before = user_count()

      conn =
        conn
        |> init_test_session(%{user_id: guest.id, user_token: guest.__metadata__.token})
        |> get(~p"/guest")

      assert redirected_to(conn) == "/"
      assert user_count() == before
      assert get_session(conn, :user_id) == guest.id
    end

    test "a session the pages would sign out gets a new guest", %{conn: conn} do
      user = create_user()
      revoked = mint_token!(user)
      :ok = TokenResource.Actions.revoke(Accounts.Token, revoked)

      for session <- [%{user_id: user.id}, %{user_id: user.id, user_token: revoked}] do
        before = user_count()

        conn =
          conn
          |> init_test_session(session)
          |> get(~p"/guest")

        assert redirected_to(conn) == "/"
        assert user_count() == before + 1
        guest_id = get_session(conn, :user_id)
        refute guest_id == user.id
        assert {:ok, guest} = Accounts.get_user_by_id(guest_id)
        assert token_valid?(guest, get_session(conn, :user_token))
      end
    end

    test "without a session it creates a guest, signs it in and redirects", %{conn: conn} do
      before = user_count()

      conn =
        conn
        |> init_test_session(%{})
        |> get(~p"/guest?return_to=/past-games")

      assert redirected_to(conn) == "/past-games"
      assert user_count() == before + 1

      guest_id = get_session(conn, :user_id)
      assert {:ok, %{is_guest: true} = guest} = Accounts.get_user_by_id(guest_id)
      assert token_valid?(guest, get_session(conn, :user_token))

      # The next page request's middleware adopts it as Hologram's identity.
      server = LoadCurrentUser.call(%Hologram.Server{session: get_session(conn)}, [])
      assert server.user_id == guest_id
      assert server.stash.current_user.id == guest_id
    end

    test "an unknown or malformed session user id gets a new guest", %{conn: conn} do
      for stale <- [Ecto.UUID.generate(), "not-a-uuid"] do
        before = user_count()

        conn =
          conn
          |> init_test_session(%{user_id: stale})
          |> get(~p"/guest")

        assert redirected_to(conn) == "/"
        assert user_count() == before + 1
        refute get_session(conn, :user_id) == stale
      end
    end

    test "only redirects to local paths", %{conn: conn} do
      user = create_user()

      for {return_to, expected} <- [
            {"//evil.example", "/"},
            {"https://evil.example", "/"},
            {"/rooms", "/rooms"}
          ] do
        conn =
          conn
          |> init_test_session(%{user_id: user.id, user_token: mint_token!(user)})
          |> get("/guest", %{"return_to" => return_to})

        assert redirected_to(conn) == expected
      end
    end
  end
end
