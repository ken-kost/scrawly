defmodule ScrawlyWeb.IdentityWritersTest do
  @moduledoc """
  Every Hologram command that signs a browser in leaves a session the pages'
  check accepts (stored token of that user) and records Hologram's identity
  (`put_user_id`). Revoking tokens (password change, recovery reset) signs the
  other browsers out on their next request; the acting one stays signed in.
  AuthController's writers are covered in auth_controller_test.exs.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.SessionTestHelpers

  alias Hologram.Server
  alias Scrawly.Accounts
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Middleware.LoadCurrentUser
  alias ScrawlyWeb.Pages.{HomePage, ProfilePage}

  @moduletag :capture_log

  defp unique_email, do: "writer-#{System.unique_integer([:positive])}@example.com"

  defp register!(password \\ "old-password-1") do
    email = unique_email()
    {:ok, user} = Accounts.register_with_password(email, password)
    {email, user}
  end

  # A signed-out page request's server, after the page's middleware.
  defp anon_page_server(page), do: run_page_middleware(page, %Server{session: %{}})

  # The browser's next request: its session after this response, through the
  # page middleware.
  defp next_request(%Server{session: session}),
    do: LoadCurrentUser.call(%Server{session: session}, [])

  describe "sign-in commands" do
    test "AppLayout :login" do
      {email, user} = register!()

      result =
        AppLayout.command(:login, %{email: email, password: "old-password-1"}, %Server{
          session: %{}
        })

      assert result.next_action.name == :auth_success
      assert_signed_in_as(result, user)
      assert next_request(result).user_id == user.id
    end

    test "AppLayout :register" do
      result =
        AppLayout.command(:register, %{email: unique_email(), password: "password123"}, %Server{
          session: %{}
        })

      assert result.next_action.name == :show_recovery_code
      {:ok, user} = Accounts.get_user_by_id(result.session["user_id"])
      assert_signed_in_as(result, user)
    end

    test "HomePage :register for a signed-out visitor" do
      result =
        HomePage.command(
          :register,
          %{email: unique_email(), password: "password123"},
          anon_page_server(HomePage)
        )

      assert result.next_action.name == :show_recovery_code
      {:ok, user} = Accounts.get_user_by_id(result.session["user_id"])
      assert user.is_guest == false
      assert_signed_in_as(result, user)
    end

    test "HomePage :register upgrading the session's guest" do
      guest = Accounts.register_as_guest!()
      server = signed_in_server(guest)

      result =
        HomePage.command(:register, %{email: unique_email(), password: "password123"}, server)

      assert result.next_action.name == :show_recovery_code
      {:ok, upgraded} = Accounts.get_user_by_id(guest.id)
      assert upgraded.is_guest == false
      token = assert_signed_in_as(result, upgraded)
      refute token == server.session["user_token"]
      assert next_request(result).stash.current_user.is_guest == false
    end

    test "HomePage :sign_in" do
      {email, user} = register!()

      result =
        HomePage.command(
          :sign_in,
          %{email: email, password: "old-password-1"},
          anon_page_server(HomePage)
        )

      assert result.next_action.name == :reload_home
      assert_signed_in_as(result, user)
    end

    test "HomePage :sign_in over another account's session switches the identity" do
      {_email, other} = register!()
      {email, user} = register!()

      result =
        HomePage.command(
          :sign_in,
          %{email: email, password: "old-password-1"},
          signed_in_server(other)
        )

      assert_signed_in_as(result, user)
    end

    test "a failed sign-in writes no identity" do
      {email, _user} = register!()
      server = anon_page_server(HomePage)

      result = HomePage.command(:sign_in, %{email: email, password: "wrong-password"}, server)

      assert result.user_id == nil
      assert session_puts(result) == %{}
    end
  end

  describe "recovery reset" do
    for owner <- [HomePage, AppLayout] do
      @owner owner

      test "#{inspect(owner)} :reset_password signs this browser in and the others out" do
        {email, user} = register!("old-password-1")
        other_browser = session_server(user)
        assert next_request(other_browser).user_id == user.id

        server =
          if @owner == HomePage, do: anon_page_server(HomePage), else: %Server{session: %{}}

        result =
          @owner.command(
            :reset_password,
            %{
              email: email,
              recovery_code: user.__metadata__.recovery_code,
              password: "new-password-1",
              password_confirmation: "new-password-1"
            },
            server
          )

        assert result.next_action.name == :show_recovery_code
        assert_signed_in_as(result, user)

        signed_out = next_request(other_browser)
        assert signed_out.user_id == nil
        assert signed_out.stash.current_user == nil
      end
    end
  end

  describe "ProfilePage :save_password" do
    defp change_password(server, current, new) do
      ProfilePage.command(
        :save_password,
        %{current_password: current, password: new, password_confirmation: new},
        server
      )
    end

    test "signs the second browser out and keeps the acting one signed in" do
      {_email, user} = register!("old-password-1")
      browser_a = session_server(user)
      browser_b = session_server(user)
      old_a = browser_a.session["user_token"]
      old_b = browser_b.session["user_token"]

      result =
        browser_a
        |> then(&run_page_middleware(ProfilePage, &1))
        |> change_password("old-password-1", "new-password-1")

      assert result.next_action.name == :password_saved
      assert result.next_action.params.message =~ "signed out"

      new_a = assert_signed_in_as(result, user)
      refute new_a == old_a
      refute token_valid?(user, old_a)
      refute token_valid?(user, old_b)

      # Browser A's next page load is still signed in, with the new token.
      assert next_request(result).stash.current_user.id == user.id

      # Browser B's next page load is signed out; /profile sends it home.
      b_next = next_request(browser_b)
      assert b_next.user_id == nil
      assert "user_token" in session_deletes(b_next)

      assert run_page_middleware(ProfilePage, browser_b).response_headers["location"] == "/"
    end

    test "a wrong current password changes and revokes nothing" do
      {_email, user} = register!("old-password-1")
      browser_a = session_server(user)
      token = browser_a.session["user_token"]

      result =
        browser_a
        |> then(&run_page_middleware(ProfilePage, &1))
        |> change_password("wrong-password-1", "new-password-1")

      assert result.next_action.name == :password_failed
      assert session_puts(result) == %{}
      assert token_valid?(user, token)
    end
  end
end
