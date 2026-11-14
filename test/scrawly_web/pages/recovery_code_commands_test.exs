defmodule ScrawlyWeb.Pages.RecoveryCodeCommandsTest do
  use Scrawly.DataCase, async: false

  alias Hologram.Server
  alias Scrawly.Accounts
  alias Scrawly.Accounts.{RecoveryCode, User}
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Pages.{HomePage, ProfilePage}

  @code_format ~r/^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){4}$/

  defp unique_email, do: "recovery-cmd-#{System.unique_integer([:positive])}@example.com"

  defp register!(password \\ "old-password-1") do
    email = unique_email()
    {:ok, user} = Accounts.register_with_password(email, password)
    {email, user}
  end

  defp anon_server, do: %Server{session: %{}}
  defp server_for(user), do: %Server{session: %{"user_id" => user.id}}

  defp session_puts(server) do
    for {key, {:put, value}} <- Server.get_session_ops(server), into: %{}, do: {key, value}
  end

  defp refute_code_in_session(server, code) do
    for {_key, value} <- session_puts(server) do
      refute inspect(value) =~ code
      refute inspect(value) =~ RecoveryCode.normalize(code)
    end
  end

  defp verifies?(token), do: match?({:ok, _, _}, AshAuthentication.Jwt.verify(token, User))

  defp reset_params(email, code, password \\ "new-password-1", confirmation \\ nil) do
    %{
      email: email,
      recovery_code: code,
      password: password,
      password_confirmation: confirmation || password
    }
  end

  describe "registration shows the code instead of finishing straight away" do
    test "HomePage :register replies with the code and signs the session in" do
      result =
        HomePage.command(
          :register,
          %{email: unique_email(), password: "password123"},
          anon_server()
        )

      assert result.next_action.name == :show_recovery_code
      code = result.next_action.params.code
      assert Regex.match?(@code_format, code)

      session = session_puts(result)
      assert is_binary(session["user_id"])
      assert verifies?(session["user_token"])
      refute_code_in_session(result, code)
    end

    test "HomePage :register upgrading a guest also replies with a code" do
      guest = Accounts.register_as_guest!()

      result =
        HomePage.command(
          :register,
          %{email: unique_email(), password: "password123"},
          server_for(guest)
        )

      assert result.next_action.name == :show_recovery_code
      assert Regex.match?(@code_format, result.next_action.params.code)
      assert session_puts(result)["user_id"] == guest.id
    end

    test "AppLayout :register replies with the code and the header data for :auth_success" do
      result =
        AppLayout.command(
          :register,
          %{email: unique_email(), password: "password123"},
          anon_server()
        )

      assert result.next_action.name == :show_recovery_code
      params = result.next_action.params
      assert Regex.match?(@code_format, params.code)
      assert is_binary(params.username)
      assert Map.has_key?(params, :avatar_id)
      assert verifies?(session_puts(result)["user_token"])
      refute_code_in_session(result, params.code)
    end
  end

  describe ":reset_password" do
    for owner <- [HomePage, AppLayout] do
      @owner owner

      test "#{inspect(owner)} signs the browser in and shows the new code" do
        {email, user} = register!("old-password-1")
        old_code = user.__metadata__.recovery_code

        result = @owner.command(:reset_password, reset_params(email, old_code), anon_server())

        assert result.next_action.name == :show_recovery_code
        new_code = result.next_action.params.code
        assert Regex.match?(@code_format, new_code)
        refute new_code == old_code
        assert result.next_action.params.username == user.username

        session = session_puts(result)
        assert session["user_id"] == user.id
        assert verifies?(session["user_token"])
        refute verifies?(user.__metadata__.token)
        refute_code_in_session(result, new_code)

        assert {:error, _} = Accounts.sign_in_with_password(email, "old-password-1")
        assert {:ok, _} = Accounts.sign_in_with_password(email, "new-password-1")
      end

      test "#{inspect(owner)} reports a wrong code generically and writes no session" do
        {email, _user} = register!()

        result =
          @owner.command(
            :reset_password,
            reset_params(email, RecoveryCode.generate()),
            anon_server()
          )

        assert result.next_action.name == :recovery_reset_failed
        assert result.next_action.params.message == "email or recovery code is incorrect"
        assert session_puts(result) == %{}
      end
    end

    test "an unknown email gets the same message" do
      result =
        HomePage.command(
          :reset_password,
          reset_params(unique_email(), RecoveryCode.generate()),
          anon_server()
        )

      assert result.next_action.params.message == "email or recovery code is incorrect"
    end

    test "input problems get specific messages and nothing crashes" do
      {email, user} = register!()
      code = user.__metadata__.recovery_code

      message = fn params ->
        result = HomePage.command(:reset_password, params, anon_server())
        assert result.next_action.name == :recovery_reset_failed
        assert session_puts(result) == %{}
        result.next_action.params.message
      end

      assert message.(reset_params(email, code, "new-password-1", "other-password-1")) =~
               "don't match"

      assert message.(reset_params(email, code, "short")) =~ "at least 8 characters"
      assert message.(%{}) =~ "fill in"
      assert message.(%{email: 1, recovery_code: [:x], password: %{}}) =~ "fill in"

      # None of that touched the account.
      assert {:ok, _} = Accounts.sign_in_with_password(email, "old-password-1")
    end

    test "too many failures are reported as such" do
      {email, user} = register!()

      for _ <- 1..5 do
        HomePage.command(
          :reset_password,
          reset_params(email, RecoveryCode.generate()),
          anon_server()
        )
      end

      result =
        HomePage.command(
          :reset_password,
          reset_params(email, user.__metadata__.recovery_code),
          anon_server()
        )

      assert result.next_action.name == :recovery_reset_failed
      assert result.next_action.params.message =~ "too many attempts"
    end
  end

  describe "ProfilePage :regenerate_recovery_code" do
    test "with the current password it replies with a new code and its date" do
      {email, user} = register!("old-password-1")
      old_code = user.__metadata__.recovery_code

      result =
        ProfilePage.command(
          :regenerate_recovery_code,
          %{current_password: "old-password-1"},
          server_for(user)
        )

      assert result.next_action.name == :show_recovery_code
      new_code = result.next_action.params.code
      assert Regex.match?(@code_format, new_code)
      refute new_code == old_code
      assert result.next_action.params.generated_label =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC$/
      assert session_puts(result) == %{}

      assert {:error, _} =
               Accounts.reset_password_with_recovery_code(
                 email,
                 old_code,
                 "pw-123456",
                 "pw-123456"
               )

      assert {:ok, _} =
               Accounts.reset_password_with_recovery_code(
                 email,
                 new_code,
                 "pw-123456",
                 "pw-123456"
               )
    end

    test "a wrong password, a guest and a signed-out visitor get messages, not crashes" do
      {_email, user} = register!("old-password-1")
      guest = Accounts.register_as_guest!()

      message = fn params, server ->
        result = ProfilePage.command(:regenerate_recovery_code, params, server)
        assert result.next_action.name == :recovery_code_failed
        result.next_action.params.message
      end

      assert message.(%{current_password: "wrong-password"}, server_for(user)) ==
               "current password is incorrect"

      assert message.(%{current_password: ""}, server_for(user)) =~ "current password"
      assert message.(%{current_password: "whatever-1"}, server_for(guest)) =~ "register"
      assert message.(%{current_password: "whatever-1"}, anon_server()) =~ "sign in"
    end
  end

  describe "ProfilePage init" do
    defp init_state(user) do
      ProfilePage.init(%{}, %Hologram.Component{}, server_for(user)).state
    end

    test "shows when the code was generated" do
      {_email, user} = register!()
      state = init_state(user)

      assert state.recovery_status == :active
      assert state.recovery_generated_label =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC$/
      assert state.recovery_code == nil
    end

    test "prompts accounts that predate recovery codes" do
      user =
        Ash.create!(User, %{email: unique_email()}, authorize?: false)

      state = init_state(user)

      assert state.recovery_status == :missing
      assert state.recovery_generated_label == ""
    end

    test "tells guests to register" do
      assert init_state(Accounts.register_as_guest!()).recovery_status == :guest
    end
  end
end
