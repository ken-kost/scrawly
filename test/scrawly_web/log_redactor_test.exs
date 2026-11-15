defmodule ScrawlyWeb.LogRedactorTest do
  @moduledoc """
  QA B1, second half: a crash report never prints the Hologram server struct
  (session cookie, CSRF token, session JWT) or typed passwords. Bandit logs
  `Exception.format/3` of a crashed request, whose stacktrace shows the
  arguments of the frame that raised; `ScrawlyWeb.LogRedactor` (a primary
  logger filter installed at application start) strips them.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Hologram.Server
  alias ScrawlyWeb.LogRedactor

  @cookie "SFMyNTY.g3QAAAAEsecret-session-cookie"
  @jwt "eyJhbGciOiJIUzI1NiJ9.secret-jwt"
  @password "Typed-Password-123"

  defp server do
    %Server{
      cookies: %{"_scrawly_key" => @cookie},
      session: %{"user_id" => "u1", "user_token" => @jwt, "_csrf_token" => "csrf-secret"}
    }
  end

  # What Bandit logs for a crashed request (Bandit.Pipeline.handle_error/7).
  defp log_like_bandit(kind, reason, stacktrace) do
    reason = Exception.normalize(kind, reason, stacktrace)

    crash_reason =
      if kind == :throw, do: {{:nocatch, reason}, stacktrace}, else: {reason, stacktrace}

    Logger.error(Exception.format(kind, reason, stacktrace),
      domain: [:bandit],
      crash_reason: crash_reason
    )
  end

  defp crash(fun) do
    fun.()
    flunk("expected a raise")
  rescue
    error -> {error, __STACKTRACE__}
  catch
    kind, value -> {{kind, value}, __STACKTRACE__}
  end

  defp refute_secrets(log) do
    for secret <- [@cookie, @jwt, "csrf-secret", @password], do: refute(log =~ secret)
  end

  test "is installed as a primary logger filter" do
    assert {_fun, []} = :logger.get_primary_config().filters[:scrawly_redact_crash_args]
  end

  test "a FunctionClauseError of a command (forged params) logs no server or params" do
    {error, stacktrace} =
      crash(fn ->
        ScrawlyWeb.Pages.GamePage.Commands.leave_room(%{password: @password}, server())
      end)

    log = capture_log(fn -> log_like_bandit(:error, error, stacktrace) end)

    assert log =~ "FunctionClauseError"
    assert log =~ "ScrawlyWeb.Pages.GamePage.Commands.leave_room/"
    refute log =~ "%Hologram.Server{"
    refute_secrets(log)
  end

  test "an UndefinedFunctionError (a forged command naming a module without command/3)" do
    {error, stacktrace} = crash(fn -> apply(Hologram.UI.Link, :command, [:x, %{}, server()]) end)

    log = capture_log(fn -> log_like_bandit(:error, error, stacktrace) end)

    assert log =~ "Hologram.UI.Link.command/3"
    refute_secrets(log)
  end

  test "an exception whose own fields hold the server or a password (KeyError, MatchError)" do
    {key_error, st} = crash(fn -> Map.fetch!(%{password: @password, server: server()}, :nope) end)
    log = capture_log(fn -> log_like_bandit(:error, key_error, st) end)
    assert log =~ "KeyError"
    refute_secrets(log)

    {match_error, st} =
      crash(fn ->
        send(self(), {:error, server()})

        receive do
          reply -> {:ok, _} = reply
        end
      end)

    log = capture_log(fn -> log_like_bandit(:error, match_error, st) end)
    assert log =~ "MatchError"
    refute_secrets(log)
  end

  test "throws and exits are rebuilt too" do
    {{:throw, value}, st} = crash(fn -> throw(server()) end)
    refute_secrets(capture_log(fn -> log_like_bandit(:throw, value, st) end))

    {{:exit, reason}, st} = crash(fn -> exit({:bad, %{user_token: @jwt}}) end)
    refute_secrets(capture_log(fn -> log_like_bandit(:exit, reason, st) end))
  end

  describe "filter/2" do
    test "strips frame arguments from the crash_reason metadata" do
      stacktrace = [{Mod, :fun, [server(), @password], [file: ~c"x.ex", line: 1]}]
      error = %FunctionClauseError{module: Mod, function: :fun, arity: 2, args: [server()]}

      event = %{
        level: :error,
        msg: {:string, "** (FunctionClauseError) ..."},
        meta: %{crash_reason: {error, stacktrace}}
      }

      %{msg: {:string, msg}, meta: %{crash_reason: {clean_error, clean_stack}}} =
        LogRedactor.filter(event, [])

      assert clean_stack == [{Mod, :fun, 2, [file: ~c"x.ex", line: 1]}]
      assert clean_error.args == nil
      refute_secrets(IO.chardata_to_string(msg))
    end

    test "leaves events without argument lists untouched" do
      event = %{level: :info, msg: {:string, "hello"}, meta: %{}}
      assert LogRedactor.filter(event, []) == event

      with_reason = %{event | meta: %{crash_reason: {:oops, [{Mod, :fun, 2, []}]}}}
      assert LogRedactor.filter(with_reason, []) == with_reason
    end

    test "keeps a non-exception message (e.g. a GenServer report) and scrubs the metadata" do
      stacktrace = [{Mod, :fun, [server()], []}]

      event = %{
        level: :error,
        msg: {:string, "GenServer terminating"},
        meta: %{crash_reason: {:oops, stacktrace}}
      }

      %{msg: msg, meta: %{crash_reason: {:oops, [{Mod, :fun, 1, []}]}}} =
        LogRedactor.filter(event, [])

      assert msg == {:string, "GenServer terminating"}
    end
  end
end
