defmodule Scrawly.Accounts.RecoveryConcurrencyTest do
  @moduledoc """
  QA auth #6 and #7 (T4, T5): recovery resets and code regeneration under real
  concurrency.

  These tests use real pooled connections against the test database (sandbox
  `:auto` mode), so transactions really run in parallel and row locks really
  block. Every row they create is deleted on exit.
  """
  use ExUnit.Case, async: false

  alias Scrawly.Accounts
  alias Scrawly.Accounts.{RecoveryCode, Throttle}
  alias Scrawly.Accounts.Errors.RecoveryRejected

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Scrawly.Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Scrawly.Repo, :manual) end)
    :ok
  end

  defp register!(prefix) do
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_with_password(email, "old-password-1")

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Scrawly.Repo, :auto)
      Scrawly.Repo.query!("DELETE FROM tokens WHERE subject = $1", ["user?id=#{user.id}"])
      Scrawly.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
      Throttle.clear(:recovery_email, String.downcase(email))
    end)

    {email, user}
  end

  defp in_parallel(n, fun) do
    1..n
    |> Enum.map(fn i -> Task.async(fn -> fun.(i) end) end)
    |> Task.await_many(60_000)
  end

  defp reason({:error, %{errors: [%RecoveryRejected{reason: reason}]}}), do: reason
  defp reason(other), do: flunk("expected a RecoveryRejected error, got: #{inspect(other)}")

  test "T4: parallel wrong codes get exactly 5 bcrypt checks, the rest are throttled" do
    {email, _user} = register!("t4")

    results =
      in_parallel(20, fn _ ->
        Accounts.reset_password_with_recovery_code(
          email,
          "AAAA-AAAA-AAAA-AAAA-AAAA",
          "new-password-1",
          "new-password-1"
        )
      end)

    assert results |> Enum.map(&reason/1) |> Enum.frequencies() == %{incorrect: 5, throttled: 15}
  end

  test "T5: the same code used twice at once resets once; the shown code and token are good" do
    {email, user} = register!("t5")
    code = user.__metadata__.recovery_code

    results =
      in_parallel(2, fn i ->
        Accounts.reset_password_with_recovery_code(
          email,
          code,
          "new-password-#{i}",
          "new-password-#{i}"
        )
      end)

    assert [winner] = for({:ok, u} <- results, do: u)
    assert [:incorrect] = for({:error, _} = e <- results, do: reason(e))

    assert {:ok, _, _} =
             ScrawlyWeb.Auth.verify_session_token(winner.id, winner.__metadata__.token)

    {:ok, final} = Accounts.get_user_by_id(user.id)
    new_code = RecoveryCode.normalize(winner.__metadata__.recovery_code)
    assert Bcrypt.verify_pass(new_code, final.hashed_recovery_code)
  end

  test "regenerating twice at once issues one code, the one stored" do
    {email, user} = register!("regen")

    results =
      in_parallel(2, fn _ -> Accounts.regenerate_recovery_code(user, "old-password-1") end)

    assert [winner] = for({:ok, u} <- results, do: u)

    assert [%Ash.Error.Invalid{errors: errors}] = for({:error, e} <- results, do: e)
    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    {:ok, final} = Accounts.get_user_by_id(user.id)

    assert Bcrypt.verify_pass(
             RecoveryCode.normalize(winner.__metadata__.recovery_code),
             final.hashed_recovery_code
           )

    assert {:ok, _} =
             Accounts.reset_password_with_recovery_code(
               email,
               winner.__metadata__.recovery_code,
               "new-password-9",
               "new-password-9"
             )
  end

  test "a reset and a regenerate with the same old code: exactly one of them wins" do
    {email, user} = register!("mixed")
    code = user.__metadata__.recovery_code

    [reset, regen] =
      in_parallel(2, fn
        1 ->
          Accounts.reset_password_with_recovery_code(
            email,
            code,
            "new-password-1",
            "new-password-1"
          )

        2 ->
          Accounts.regenerate_recovery_code(user, "old-password-1")
      end)

    assert match?({:ok, _}, reset) != match?({:ok, _}, regen)

    {:ok, final} = Accounts.get_user_by_id(user.id)
    {:ok, winner} = if match?({:ok, _}, reset), do: reset, else: regen

    assert Bcrypt.verify_pass(
             RecoveryCode.normalize(winner.__metadata__.recovery_code),
             final.hashed_recovery_code
           )
  end
end
