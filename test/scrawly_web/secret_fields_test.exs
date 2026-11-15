defmodule ScrawlyWeb.SecretFieldsTest do
  @moduledoc """
  QA auth #2 / client C3: passwords and recovery codes never sit in component
  state, which Hologram renders into the HTML and snapshots for Back/Forward.
  Their inputs are not synchronized (no value binding, no `$change`); the
  `$submit` actions read them from the event; every failure, hide and switch
  empties them in the DOM; nothing secret is put in state on any path.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.JsCallTrace, only: [js_execs: 1]

  alias Hologram.Component
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Pages.{HomePage, ProfilePage}

  @owners %{
    AppLayout => "lib/scrawly_web/layouts/app_layout.ex",
    HomePage => "lib/scrawly_web/pages/home_page.ex",
    ProfilePage => "lib/scrawly_web/pages/profile_page.ex"
  }

  @secret "Typed-Secret-123"

  # Every key that ever held a typed secret before the fix.
  @secret_keys ~w(login_password register_password reset_code reset_password
                  reset_password_confirmation current_password new_password
                  new_password_confirmation recovery_password)a

  defp secret_inputs(source) do
    ~r/<input\b[^>]*>/s
    |> Regex.scan(source)
    |> List.flatten()
    |> Enum.filter(&(&1 =~ ~r/type="password"|name="recovery_code"/))
  end

  defp clears_secret_fields?(execs), do: Enum.any?(execs, &(&1 =~ "input[data-secret]"))

  defp layout(state), do: %Component{state: Map.merge(layout_state(), state)}

  defp layout_state do
    %{
      show_login_modal: true,
      show_register_modal: false,
      show_reset_modal: false,
      login_email: "a@b.c",
      register_email: "",
      reset_email: "",
      auth_error: nil,
      reset_error: nil
    }
  end

  defp home(state) do
    %Component{
      state:
        Map.merge(
          %{
            show_login_modal: true,
            login_email: "a@b.c",
            login_error: "",
            auth_intent: :register,
            show_reset_modal: false,
            reset_email: "",
            reset_error: ""
          },
          state
        )
    }
  end

  defp profile(state) do
    %Component{
      state:
        Map.merge(
          %{
            password_error: nil,
            password_message: nil,
            recovery_error: nil,
            recovery_message: nil
          },
          state
        )
    }
  end

  defp submit(fields), do: %{event: fields}

  defp refute_secret_in_state(%Component{state: state}) do
    refute Enum.any?(@secret_keys, &Map.has_key?(state, &1))
    refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ @secret
  end

  test "password and recovery-code inputs are not synchronized and are marked data-secret" do
    for {_module, path} <- @owners do
      inputs = path |> File.read!() |> secret_inputs()
      assert inputs != [], "no secret inputs found in #{path}"

      for input <- inputs do
        assert input =~ ~s(data-secret="1"), "#{path}: #{input}"
        refute input =~ "value=", "#{path}: #{input}"
        refute input =~ "$change", "#{path}: #{input}"
      end
    end
  end

  test "no init state holds a secret key" do
    for {module, path} <- @owners, key <- @secret_keys do
      refute File.read!(path) =~ "put_state(:#{key}", "#{inspect(module)} still puts #{key}"
    end
  end

  describe "AppLayout" do
    test "submits read the secrets from the event, never from state" do
      login =
        AppLayout.action(
          :submit_login,
          submit(%{"email" => "x", "password" => @secret}),
          layout(%{})
        )

      assert login.next_command.params == %{email: "a@b.c", password: @secret}
      refute_secret_in_state(login)

      register =
        AppLayout.action(
          :submit_register,
          submit(%{"password" => @secret}),
          layout(%{register_email: "r@b.c"})
        )

      assert register.next_command.params == %{email: "r@b.c", password: @secret}

      reset =
        AppLayout.action(
          :submit_reset,
          submit(%{
            "recovery_code" => @secret,
            "new_password" => @secret <> "n",
            "new_password_confirmation" => @secret <> "c"
          }),
          layout(%{reset_email: "z@b.c"})
        )

      assert reset.next_command.params == %{
               email: "z@b.c",
               recovery_code: @secret,
               password: @secret <> "n",
               password_confirmation: @secret <> "c"
             }

      refute_secret_in_state(reset)
    end

    test "a forged submit without the fields sends empty strings" do
      result = AppLayout.action(:submit_login, %{}, layout(%{}))
      assert result.next_command.params.password == ""
    end

    test "failures, hides and switches empty the secret inputs" do
      for {name, params} <- [
            {:auth_error, %{message: "nope"}},
            {:recovery_reset_failed, %{message: "nope"}},
            {:hide_auth_modal, %{}},
            {:switch_to_register, %{}},
            {:switch_to_login, %{}},
            {:show_reset, %{}}
          ] do
        {result, execs} = js_execs(fn -> AppLayout.action(name, params, layout(%{})) end)
        assert clears_secret_fields?(execs), "#{name} leaves the inputs filled"
        refute_secret_in_state(result)
      end
    end
  end

  describe "HomePage" do
    test "both buttons submit the form; the clicked one picks the command" do
      signed =
        home(%{})
        |> then(&HomePage.action(:set_auth_intent, %{intent: :sign_in}, &1))
        |> then(&HomePage.action(:submit_auth, submit(%{"password" => @secret}), &1))

      assert signed.next_command.name == :sign_in
      assert signed.next_command.params == %{email: "a@b.c", password: @secret}
      assert signed.state.auth_intent == :register
      refute_secret_in_state(signed)

      registered = HomePage.action(:submit_auth, submit(%{"password" => @secret}), home(%{}))
      assert registered.next_command.name == :register
    end

    test "the reset submit reads the code and passwords from the event" do
      result =
        HomePage.action(
          :submit_reset,
          submit(%{
            "recovery_code" => @secret,
            "new_password" => "p1-#{@secret}",
            "new_password_confirmation" => "p2-#{@secret}"
          }),
          home(%{reset_email: "z@b.c"})
        )

      assert result.next_command.params.recovery_code == @secret
      refute_secret_in_state(result)
    end

    test "failures and hides empty the secret inputs" do
      for {name, params} <- [
            {:login_failed, %{message: "nope"}},
            {:recovery_reset_failed, %{message: "nope"}},
            {:hide_login, %{}},
            {:hide_reset, %{}},
            {:show_reset, %{}},
            {:show_recovery_code, %{code: "CODE"}}
          ] do
        {result, execs} =
          js_execs(fn ->
            HomePage.action(name, params, home(%{recovery_code: nil, recovery_code_saved: false}))
          end)

        assert clears_secret_fields?(execs), "#{name} leaves the inputs filled"
        refute_secret_in_state(result)
      end
    end
  end

  describe "ProfilePage" do
    test "the password and recovery forms read their fields from the event" do
      saved =
        ProfilePage.action(
          :save_password,
          submit(%{
            "current_password" => @secret,
            "new_password" => "n-#{@secret}",
            "new_password_confirmation" => "c-#{@secret}"
          }),
          profile(%{})
        )

      assert saved.next_command.params == %{
               current_password: @secret,
               password: "n-#{@secret}",
               password_confirmation: "c-#{@secret}"
             }

      refute_secret_in_state(saved)

      regen =
        ProfilePage.action(
          :regenerate_recovery_code,
          submit(%{"recovery_current_password" => @secret}),
          profile(%{})
        )

      assert regen.next_command.params == %{current_password: @secret}
      refute_secret_in_state(regen)
    end

    test "every reply empties the password inputs" do
      for {name, params} <- [
            {:password_failed, %{message: "nope"}},
            {:password_saved, %{message: "ok"}},
            {:recovery_code_failed, %{message: "nope"}},
            {:show_recovery_code, %{code: "CODE", generated_label: ""}}
          ] do
        {result, execs} = js_execs(fn -> ProfilePage.action(name, params, profile(%{})) end)
        assert clears_secret_fields?(execs), "#{name} leaves the inputs filled"
        refute_secret_in_state(result)
      end
    end
  end
end
