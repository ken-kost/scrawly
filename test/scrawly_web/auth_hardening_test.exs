defmodule ScrawlyWeb.AuthHardeningTest do
  @moduledoc """
  Regression tests for the QA accounts/auth review and the end-to-end pass:

    * #4 (T2, T2b, T2c): a guest's password change fails validation instead of
      crashing in bcrypt, and nothing echoes the typed passwords;
    * #5 (T1): upgrading a guest revokes the guest's tokens; a session that
      gets a new token (account switch, renewal) retires the old one;
    * #8 (T8): /guest checks return_to before anything else and is throttled
      per client IP;
    * #9 (T3): sign-out is a CSRF-checked Hologram command (no GET), and the
      session cookie is secure in prod;
    * B2 / C4: profile errors are fixed texts, never Ash's (which quote values).
  """
  use ScrawlyWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Scrawly.SessionTestHelpers

  alias Hologram.Server
  alias Hologram.Template.Renderer
  alias Scrawly.Accounts
  alias Scrawly.Accounts.Throttle
  alias Scrawly.Repo
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Middleware.LoadCurrentUser
  alias ScrawlyWeb.Pages.{HomePage, ProfilePage}

  @moduletag :capture_log

  defp unique_email, do: "harden-#{System.unique_integer([:positive])}@example.com"

  defp register!(password \\ "old-password-1") do
    email = unique_email()
    {:ok, user} = Accounts.register_with_password(email, password)
    {email, user}
  end

  defp jti(token), do: token |> AshAuthentication.Jwt.peek() |> elem(1) |> Map.fetch!("jti")

  defp expires_at(token) do
    %{rows: [[at]]} =
      Repo.query!("SELECT expires_at FROM tokens WHERE jti = $1 AND purpose = 'user'", [
        jti(token)
      ])

    DateTime.from_naive!(at, "Etc/UTC")
  end

  defp user_count, do: Accounts.User |> Ash.count!(authorize?: false)

  defp profile_server(user), do: run_page_middleware(ProfilePage, session_server(user))

  describe "guest password change (#4, T2)" do
    test "the action rejects a guest by validation, without the typed passwords in the error" do
      guest = Accounts.register_as_guest!()

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.change_password(guest, %{
                 current_password: "MyGuessPw-123",
                 password: "NewSecret-456",
                 password_confirmation: "NewSecret-456"
               })

      message = Exception.message(error)
      assert message =~ "register an account"
      refute message =~ "MyGuessPw-123"
      refute message =~ "NewSecret-456"
    end

    test "ProfilePage :save_password answers a guest with a fixed text and logs no password" do
      guest = Accounts.register_as_guest!()

      log =
        capture_log(fn ->
          result =
            ProfilePage.command(
              :save_password,
              %{
                current_password: "MyGuessPw-123",
                password: "NewSecret-456",
                password_confirmation: "NewSecret-456"
              },
              profile_server(guest)
            )

          assert result.next_action.name == :password_failed
          assert result.next_action.params.message == "register an account to set a password."
        end)

      refute log =~ "MyGuessPw-123"
      refute log =~ "NewSecret-456"
    end

    test "a guest's profile shows no password form; an account's does" do
      guest = Accounts.register_as_guest!()
      {_email, user} = register!()

      render = fn server ->
        component = ProfilePage.init(%{}, %Hologram.Component{}, server)

        {html, _registry, _server} =
          ProfilePage.template().(component.state)
          |> Renderer.render_dom(%Renderer.Env{}, %Server{})

        html
      end

      guest_html = render.(profile_server(guest))
      refute guest_html =~ ~s(name="current_password")
      assert guest_html =~ "guests have no password"

      assert render.(profile_server(user)) =~ ~s(name="current_password")
    end
  end

  describe "profile error messages (B2, C4)" do
    test "password errors are fixed texts that never echo what was typed" do
      {_email, user} = register!()

      message = fn params ->
        result = ProfilePage.command(:save_password, params, profile_server(user))
        assert result.next_action.name == :password_failed
        result.next_action.params.message
      end

      mismatch =
        message.(%{
          current_password: "old-password-1",
          password: "Mismatch-AAA-1",
          password_confirmation: "Mismatch-BBB-2"
        })

      assert mismatch == "the new passwords don't match."

      assert message.(%{
               current_password: "wrong-pw-1",
               password: "Brand-New-1",
               password_confirmation: "Brand-New-1"
             }) ==
               "current password is incorrect."

      assert message.(%{
               current_password: "old-password-1",
               password: "short",
               password_confirmation: "short"
             }) ==
               "use a new password of at least 8 characters."

      assert message.(%{current_password: "", password: "", password_confirmation: ""}) ==
               "fill in all three password fields."
    end

    test "profile errors are fixed texts (a reserved username, bad lengths, a bad colour)" do
      {_email, user} = register!()

      message = fn params ->
        input =
          Map.merge(%{username: "fine_name", avatar_id: "a-mushroom", avatar_color: "3"}, params)

        result = ProfilePage.command(:save_profile, input, profile_server(user))
        assert result.next_action.name == :profile_failed
        result.next_action.params.message
      end

      assert message.(%{username: "System"}) == "that username is reserved. pick another one."
      assert message.(%{username: "x"}) == "use a username of 2 to 20 characters."
      assert message.(%{avatar_color: "99"}) == "pick an avatar and a tile color from the lists."
    end
  end

  describe "replaced and upgraded tokens (#5, T1)" do
    test "upgrading a guest revokes the guest's tokens and keeps the new one" do
      guest = Accounts.register_as_guest!()
      old = guest.__metadata__.token
      server = signed_in_server(guest)

      result =
        HomePage.command(:register, %{email: unique_email(), password: "password123"}, server)

      assert result.next_action.name == :show_recovery_code
      {:ok, upgraded} = Accounts.get_user_by_id(guest.id)
      refute token_valid?(upgraded, old)
      refute token_valid?(upgraded, server.session["user_token"])
      assert_signed_in_as(result, upgraded)
    end

    test "signing in over another account's session retires its token after a short grace" do
      {_other_email, other} = register!()
      {email, _user} = register!()
      server = signed_in_server(other)
      outgoing = server.session["user_token"]

      result = HomePage.command(:sign_in, %{email: email, password: "old-password-1"}, server)
      assert result.next_action.name == :reload_home

      # Still valid for requests already in flight, gone within a minute.
      assert token_valid?(other, outgoing)
      assert DateTime.diff(expires_at(outgoing), DateTime.utc_now()) in 0..60
    end

    test "a token renewed by LoadCurrentUser is retired too" do
      {_email, user} = register!()
      old = mint_token!(user)

      Repo.query!(
        "UPDATE tokens SET expires_at = (now() at time zone 'utc') + interval '2 days' WHERE jti = $1",
        [jti(old)]
      )

      renewed = LoadCurrentUser.call(session_server(user, old), [])
      new = renewed.session["user_token"]
      refute new == old

      assert DateTime.diff(expires_at(old), DateTime.utc_now()) in 0..60
      assert DateTime.diff(expires_at(new), DateTime.utc_now()) > 13 * 24 * 3600
    end
  end

  describe "sign-out (#9, T3)" do
    test "AppLayout :sign_out revokes the token, clears the session and Hologram's identity" do
      {_email, user} = register!()
      server = session_server(user) |> Server.put_session(:dark_mode, true)
      token = server.session["user_token"]

      result = AppLayout.command(:sign_out, %{}, %{server | user_id: user.id})

      assert result.next_action.name == :signed_out
      refute token_valid?(user, token)
      assert result.user_id == nil
      assert result.session == %{}
      assert Enum.sort(session_deletes(result)) == ["dark_mode", "user_id", "user_token"]
    end

    test "works for a signed-out session or a token that is already revoked" do
      assert AppLayout.command(:sign_out, %{}, %Server{session: %{}}).next_action.name ==
               :signed_out

      {_email, user} = register!()
      token = mint_token!(user)

      {:ok, _} =
        Accounts.change_password(user, %{
          current_password: "old-password-1",
          password: "new-password-1",
          password_confirmation: "new-password-1"
        })

      result = AppLayout.command(:sign_out, %{}, session_server(user, token))
      assert result.next_action.name == :signed_out
      assert result.session == %{}

      # T3c: an expired but still stored token.
      expired = mint_token!(user)

      Repo.query!(
        "UPDATE tokens SET expires_at = (now() at time zone 'utc') - interval '1 day' WHERE jti = $1",
        [jti(expired)]
      )

      result = AppLayout.command(:sign_out, %{}, session_server(user, expired))
      assert result.next_action.name == :signed_out
      assert result.session == %{}
    end

    test "the header signs out through the command; there is no GET link to /sign-out" do
      source = File.read!("lib/scrawly_web/layouts/app_layout.ex")
      refute source =~ ~s(href="/sign-out")
      assert source =~ ~s($click={action: :sign_out, target: "layout"})
    end

    test "the session cookie is secure in prod" do
      prod = Config.Reader.read!("config/prod.exs", env: :prod, target: :host)
      assert get_in(prod, [:scrawly, :secure_session_cookie]) == true

      assert File.read!("lib/scrawly_web/endpoint.ex") =~
               "secure: Application.compile_env(:scrawly, :secure_session_cookie, false)"
    end
  end

  describe "GET /guest (#8, T8)" do
    defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

    defp unique_ip do
      n = System.unique_integer([:positive])
      {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
    end

    test "an unsafe return_to redirects home without raising, and creates one usable guest", %{
      conn: conn
    } do
      for return_to <- ["/\\evil.example", "//evil.example", "/\tx", "/%09/evil", "https://x.y"] do
        before = user_count()

        conn =
          conn
          |> from_ip(unique_ip())
          |> init_test_session(%{})
          |> get("/guest", %{"return_to" => return_to})

        assert redirected_to(conn) == "/", inspect(return_to)
        assert user_count() == before + 1
      end
    end

    test "creates at most 20 guests per client IP per 10 minutes", %{conn: conn} do
      ip = unique_ip()
      {max, _window} = Throttle.limit(:guest_ip)

      for _ <- 1..max do
        conn = conn |> from_ip(ip) |> init_test_session(%{}) |> get("/guest")
        assert redirected_to(conn) == "/"
      end

      before = user_count()
      conn = conn |> from_ip(ip) |> init_test_session(%{}) |> get("/guest")

      assert conn.status == 429
      assert user_count() == before
      refute get_session(conn, :user_id)

      # Another client is not affected.
      other = build_conn() |> from_ip(unique_ip()) |> init_test_session(%{}) |> get("/guest")
      assert redirected_to(other) == "/"
    end
  end
end
