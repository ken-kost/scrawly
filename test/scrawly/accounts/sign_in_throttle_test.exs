defmodule Scrawly.Accounts.SignInThrottleTest do
  @moduledoc """
  QA auth #1: password sign-in is throttled per email and per client IP, in
  the `:sign_in_with_password` action itself (`ThrottleSignIn`), which both
  sign-in entry points (AppLayout `:login`, HomePage `:sign_in`) reach through
  `ScrawlyWeb.Auth.sign_in/3`. An attempt is counted before the bcrypt check,
  so a throttled one costs no bcrypt and parallel attempts can't get past the
  limit.
  """
  # async: false: count_bcrypt/1 sets global trace patterns; the parallel test
  # shares the sandbox connection.
  use Scrawly.DataCase, async: false

  import Scrawly.SessionTestHelpers

  alias Hologram.Server
  alias Scrawly.Accounts
  alias Scrawly.Accounts.Errors.SignInThrottled
  alias Scrawly.Accounts.Throttle
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Pages.HomePage

  @moduletag :capture_log

  defp unique_email, do: "throttle-#{System.unique_integer([:positive])}@example.com"
  defp unique_ip, do: "198.51.100.#{rem(System.unique_integer([:positive]), 250) + 1}"

  defp register!(password \\ "right-password-1") do
    email = unique_email()
    {:ok, user} = Accounts.register_with_password(email, password)
    {email, user}
  end

  defp sign_in(email, password, ip \\ nil) do
    Accounts.sign_in_with_password(email, password, context: %{client_ip: ip})
  end

  defp throttled?({:error, %{errors: errors}}),
    do: Enum.any?(errors, &match?(%SignInThrottled{}, &1))

  defp throttled?(_result), do: false

  defp email_limit, do: elem(Throttle.limit(:sign_in_email), 0)
  defp ip_limit, do: elem(Throttle.limit(:sign_in_ip), 0)

  # A page request's server from `ip`, after HomePage's middleware.
  defp anon_server(ip), do: run_page_middleware(HomePage, %Server{session: %{}, ip: ip})

  describe "per email" do
    test "after the limit even the right password is refused, and no bcrypt runs" do
      {email, _user} = register!()

      for _ <- 1..email_limit() do
        result = sign_in(email, "wrong-password")
        assert {:error, _} = result
        refute throttled?(result)
      end

      {result, bcrypt_ops} = count_bcrypt(fn -> sign_in(email, "right-password-1") end)
      assert throttled?(result)
      assert bcrypt_ops == 0

      # Other accounts are unaffected.
      {other, _} = register!()
      assert {:ok, _} = sign_in(other, "right-password-1")
    end

    test "every spelling the citext lookup accepts shares the bucket" do
      n = System.unique_integer([:positive])
      email = "victim#{n}@example.com"
      {:ok, _} = Accounts.register_with_password(email, "right-password-1")

      variants = [
        String.replace(email, "i", "İ", global: false),
        String.upcase(email),
        String.replace(email, "c", "C")
      ]

      for i <- 1..email_limit(),
          do: refute(throttled?(sign_in(Enum.at(variants, rem(i, 3)), "wrong-password")))

      assert throttled?(sign_in(email, "right-password-1"))
    end

    test "unknown emails are counted too (the limit says nothing about existence)" do
      email = unique_email()
      for _ <- 1..email_limit(), do: refute(throttled?(sign_in(email, "whatever-pass")))
      assert throttled?(sign_in(email, "whatever-pass"))
    end

    test "a successful sign-in hands its slot back" do
      {email, _user} = register!()
      key = Throttle.email_key(email)

      for _ <- 1..3, do: sign_in(email, "wrong-password")
      assert {:ok, _} = sign_in(email, "right-password-1")
      assert Throttle.attempts(:sign_in_email, key) == 3
    end

    test "malformed input is rejected before anything is counted" do
      {email, _user} = register!()
      assert {:error, _} = sign_in(email, "")
      assert {:error, _} = sign_in(nil, "right-password-1")
      assert Throttle.attempts(:sign_in_email, Throttle.email_key(email)) == 0
    end

    test "parallel attempts never get past the limit" do
      {email, _user} = register!()
      Ecto.Adapters.SQL.Sandbox.mode(Scrawly.Repo, {:shared, self()})

      results =
        1..(email_limit() * 3)
        |> Enum.map(fn _ -> Task.async(fn -> sign_in(email, "wrong-password") end) end)
        |> Task.await_many(30_000)

      # The ones not throttled are the ones that reached the bcrypt check.
      assert Enum.count(results, &(not throttled?(&1))) == email_limit()
    end
  end

  describe "per client IP" do
    test "spraying many emails from one IP is stopped; other IPs are not" do
      ip = unique_ip() <> "-spray-#{System.unique_integer([:positive])}"

      for _ <- 1..ip_limit(), do: refute(throttled?(sign_in(unique_email(), "x-password", ip)))

      {email, _user} = register!()
      assert throttled?(sign_in(email, "right-password-1", ip))
      assert {:ok, _} = sign_in(email, "right-password-1", ip <> "-other")
    end
  end

  describe "both entry points share it (ScrawlyWeb.Auth.sign_in/3)" do
    test "AppLayout :login and HomePage :sign_in fill and honour the same email bucket" do
      {email, user} = register!()

      for i <- 1..email_limit() do
        result =
          if rem(i, 2) == 0,
            do:
              AppLayout.command(:login, %{email: email, password: "nope"}, %Server{session: %{}}),
            else: HomePage.command(:sign_in, %{email: email, password: "nope"}, anon_server(nil))

        assert result.next_action.params.message =~ ~r/incorrect email or password/i
      end

      home =
        HomePage.command(
          :sign_in,
          %{email: email, password: "right-password-1"},
          anon_server(nil)
        )

      assert home.next_action.name == :login_failed
      assert home.next_action.params.message =~ "too many sign-in attempts"
      assert home.user_id == nil

      layout =
        AppLayout.command(:login, %{email: email, password: "right-password-1"}, %Server{
          session: %{}
        })

      assert layout.next_action.name == :auth_error
      assert layout.next_action.params.message =~ "Too many sign-in attempts"
      refute Map.has_key?(layout.session, "user_id")
      assert user.id
    end

    test "the client IP comes from the request (Hologram.Server ip)" do
      ip = "192.0.2.#{rem(System.unique_integer([:positive]), 250) + 1}"
      Throttle.clear(:sign_in_ip, ip)

      for _ <- 1..ip_limit(),
          do: HomePage.command(:sign_in, %{email: unique_email(), password: "x"}, anon_server(ip))

      {email, _user} = register!()

      result =
        HomePage.command(:sign_in, %{email: email, password: "right-password-1"}, anon_server(ip))

      assert result.next_action.params.message =~ "too many sign-in attempts"

      ok =
        HomePage.command(
          :sign_in,
          %{email: email, password: "right-password-1"},
          anon_server("192.0.2.254")
        )

      assert ok.next_action.name == :reload_home
      Throttle.clear(:sign_in_ip, ip)
    end

    test "with a configured proxy header, the header's address is the client IP" do
      Application.put_env(:scrawly, ScrawlyWeb.ClientIp, header: "fly-client-ip")
      on_exit(fn -> Application.delete_env(:scrawly, ScrawlyWeb.ClientIp) end)

      server = %Server{ip: "10.0.0.1", request_headers: %{"fly-client-ip" => "203.0.113.9"}}
      assert ScrawlyWeb.ClientIp.from_server(server) == "203.0.113.9"

      junk = %Server{ip: "10.0.0.1", request_headers: %{"fly-client-ip" => "not an ip"}}
      assert ScrawlyWeb.ClientIp.from_server(junk) == "10.0.0.1"
    end
  end

  # Counts bcrypt operations (hashes and verifications) run by `fun` in this
  # process (same helper as recovery_code_test.exs).
  defp count_bcrypt(fun) do
    patterns = [{Bcrypt, :verify_pass, 2}, {Bcrypt.Base, :hash_password, 2}]
    Code.ensure_loaded!(Bcrypt)
    Code.ensure_loaded!(Bcrypt.Base)
    collector = spawn_link(fn -> count_trace_calls(0) end)
    Enum.each(patterns, &(1 = :erlang.trace_pattern(&1, true, [:global])))
    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    result =
      try do
        fun.()
      after
        :erlang.trace(self(), false, [:call])
        Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:global]))
      end

    ref = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _pid, ^ref} -> :ok
    end

    send(collector, {:count, self()})

    receive do
      {:bcrypt_count, n} -> {result, n}
    end
  end

  defp count_trace_calls(n) do
    receive do
      {:trace, _pid, :call, _mfa} -> count_trace_calls(n + 1)
      {:count, from} -> send(from, {:bcrypt_count, n})
    end
  end
end
