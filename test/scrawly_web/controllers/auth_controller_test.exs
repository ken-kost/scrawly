defmodule ScrawlyWeb.AuthControllerTest do
  @moduledoc """
  GET /guest creates a guest only for a session without a valid account. The
  session cookie is SameSite=Lax, so a link to /guest must not switch a
  signed-in user to a new guest, and repeat visits must not create rows.
  """
  use ScrawlyWeb.ConnCase, async: true

  import Scrawly.RoomTestHelpers, only: [create_user: 0]

  alias Scrawly.Accounts

  defp user_count, do: Accounts.User |> Ash.count!(authorize?: false)

  describe "GET /guest" do
    test "keeps a valid registered session user and creates nothing", %{conn: conn} do
      user = create_user()
      before = user_count()

      conn =
        conn
        |> init_test_session(%{user_id: user.id, user_token: "existing-token"})
        |> get(~p"/guest?return_to=/game/abc")

      assert redirected_to(conn) == "/game/abc"
      assert user_count() == before
      assert get_session(conn, :user_id) == user.id
      assert get_session(conn, :user_token) == "existing-token"
    end

    test "keeps an existing guest on a repeat visit", %{conn: conn} do
      guest = Accounts.register_as_guest!()
      before = user_count()

      conn =
        conn
        |> init_test_session(%{user_id: guest.id})
        |> get(~p"/guest")

      assert redirected_to(conn) == "/"
      assert user_count() == before
      assert get_session(conn, :user_id) == guest.id
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
      assert {:ok, %{is_guest: true}} = Accounts.get_user_by_id(guest_id)
      assert is_binary(get_session(conn, :user_token))
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
          |> init_test_session(%{user_id: user.id})
          |> get("/guest", %{"return_to" => return_to})

        assert redirected_to(conn) == expected
      end
    end
  end
end
