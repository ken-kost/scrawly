defmodule Scrawly.Accounts.RecoveryCodeTest do
  # async: false because count_bcrypt/1 sets global trace patterns on Bcrypt
  # and the log test changes the Logger level.
  use Scrawly.DataCase, async: false

  import ExUnit.CaptureLog
  require Ash.Query

  alias Scrawly.Accounts
  alias Scrawly.Accounts.{RecoveryCode, RecoveryThrottle, Token, User}
  alias Scrawly.Accounts.Errors.RecoveryRejected

  @code_format ~r/^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){4}$/

  defp unique_email, do: "recovery-#{System.unique_integer([:positive])}@example.com"

  defp register!(password \\ "old-password-1") do
    email = unique_email()
    {:ok, user} = Accounts.register_with_password(email, password)
    {email, user}
  end

  defp reload!(user), do: Ash.get!(User, user.id, authorize?: false)

  defp reset(email, code, password \\ "new-password-1", confirmation \\ nil) do
    Accounts.reset_password_with_recovery_code(email, code, password, confirmation || password)
  end

  # The error a failed reset returns, as the single Ash error class.
  defp rejection({:error, %Ash.Error.Invalid{errors: [%RecoveryRejected{} = error]}}),
    do: error

  defp rejection(other), do: flunk("expected a RecoveryRejected error, got: #{inspect(other)}")

  # Overwrites the stored hash so a test controls the plaintext.
  defp put_known_code!(user, code) do
    {:ok, hash} = AshAuthentication.BcryptProvider.hash(RecoveryCode.normalize(code))

    Repo.query!("UPDATE users SET hashed_recovery_code = $1 WHERE id = $2", [
      hash,
      Ecto.UUID.dump!(user.id)
    ])
  end

  defp clear_code!(user) do
    Repo.query!("UPDATE users SET hashed_recovery_code = NULL WHERE id = $1", [
      Ecto.UUID.dump!(user.id)
    ])
  end

  defp tokens_for(user) do
    subject = AshAuthentication.user_to_subject(user)

    Token
    |> Ash.Query.filter(subject == ^subject)
    |> Ash.read!(authorize?: false)
  end

  defp verifies?(token), do: match?({:ok, _, _}, AshAuthentication.Jwt.verify(token, User))

  # Counts bcrypt operations (hashes and verifications) run by `fun` in this
  # process. `no_user_verify/0` (BcryptProvider.simulate/0) is a hash too.
  # A process can't usefully be its own tracer, so a collector counts the calls.
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

    # Trace messages are asynchronous; wait until all of them have arrived.
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

  describe "RecoveryCode" do
    test "generates 20 Crockford base32 characters in five groups, all different" do
      codes = for _ <- 1..50, do: RecoveryCode.generate()

      assert Enum.all?(codes, &Regex.match?(@code_format, &1))
      assert length(Enum.uniq(codes)) == 50
    end

    test "normalize ignores case, spaces and hyphens and maps O to 0 and I/L to 1" do
      assert RecoveryCode.normalize("abcd-efgh") == "ABCDEFGH"
      assert RecoveryCode.normalize("  ab cd\tef - gh ") == "ABCDEFGH"
      assert RecoveryCode.normalize("oO0-iIlL1") == "000" <> "11111"
      assert RecoveryCode.normalize(nil) == ""
    end

    test "format groups a normalized code and round-trips a generated one" do
      code = RecoveryCode.generate()

      assert RecoveryCode.format(RecoveryCode.normalize(code)) == code
      assert RecoveryCode.format("abcdefghjkmnpqrstvwx") == "ABCD-EFGH-JKMN-PQRS-TVWX"
    end
  end

  describe "issuing codes" do
    test "registration returns a code once and stores only a bcrypt hash of it" do
      {_email, user} = register!()
      code = user.__metadata__.recovery_code

      assert Regex.match?(@code_format, code)

      stored = reload!(user)
      assert "$2b$" <> _ = stored.hashed_recovery_code
      refute stored.hashed_recovery_code =~ RecoveryCode.normalize(code)
      assert Bcrypt.verify_pass(RecoveryCode.normalize(code), stored.hashed_recovery_code)
      assert %DateTime{} = stored.recovery_code_generated_at

      # Reading the user again never yields the plaintext.
      refute Map.has_key?(stored.__metadata__, :recovery_code)
      {:ok, by_id} = Accounts.get_user_by_id(user.id)
      refute Map.has_key?(by_id.__metadata__, :recovery_code)
    end

    test "the password strategy's register action (AppLayout) also returns a code" do
      strategy = AshAuthentication.Info.strategy!(User, :password)

      {:ok, user} =
        AshAuthentication.Strategy.action(strategy, :register, %{
          email: unique_email(),
          password: "password123"
        })

      assert Regex.match?(@code_format, user.__metadata__.recovery_code)
      assert is_binary(user.__metadata__.token)
    end

    test "guests get no code until they upgrade" do
      guest = Accounts.register_as_guest!()

      refute Map.has_key?(guest.__metadata__, :recovery_code)
      assert reload!(guest).hashed_recovery_code == nil

      {:ok, upgraded} =
        Accounts.upgrade_guest(guest, %{email: unique_email(), password: "password123"})

      code = upgraded.__metadata__.recovery_code
      assert Regex.match?(@code_format, code)
      assert Bcrypt.verify_pass(RecoveryCode.normalize(code), reload!(guest).hashed_recovery_code)
      assert verifies?(upgraded.__metadata__.token)
    end

    test "no plaintext code reaches the log" do
      previous = Logger.level()
      Logger.configure(level: :debug)

      {codes, log} =
        try do
          with_log([level: :debug], fn ->
            {email, user} = register!()
            first = user.__metadata__.recovery_code
            {:ok, reset_user} = reset(email, first)
            second = reset_user.__metadata__.recovery_code
            rejection(reset(email, first))
            {:ok, regenerated} = Accounts.regenerate_recovery_code(reset_user, "new-password-1")
            [first, second, regenerated.__metadata__.recovery_code]
          end)
        after
          Logger.configure(level: previous)
        end

      # The SQL log is there (so debug logging was on) but carries no code.
      assert log =~ "users"

      for code <- codes do
        refute log =~ code
        refute log =~ RecoveryCode.normalize(code)
      end
    end
  end

  describe "reset_password_with_recovery_code" do
    test "a correct reset sets the password, rotates the code and revokes old tokens" do
      {email, user} = register!("old-password-1")
      old_code = user.__metadata__.recovery_code
      old_token = user.__metadata__.token

      {:ok, %{__metadata__: %{token: other_browser}}} =
        Accounts.sign_in_with_password(email, "old-password-1")

      assert verifies?(old_token)
      assert verifies?(other_browser)

      {:ok, reset_user} = reset(email, old_code, "new-password-1")

      assert reset_user.id == user.id
      new_code = reset_user.__metadata__.recovery_code
      new_token = reset_user.__metadata__.token
      assert Regex.match?(@code_format, new_code)
      refute new_code == old_code

      # Tokens: every token stored before the reset is revoked; the new one is
      # stored and verifies.
      {:ok, %{"jti" => new_jti}} = AshAuthentication.Jwt.peek(new_token)
      {[new_row], old_rows} = Enum.split_with(tokens_for(user), &(&1.jti == new_jti))

      assert new_row.purpose == "user"
      assert length(old_rows) >= 2
      assert Enum.all?(old_rows, &(&1.purpose == "revocation"))
      refute verifies?(old_token)
      refute verifies?(other_browser)
      assert verifies?(new_token)

      # Password
      assert {:error, _} = Accounts.sign_in_with_password(email, "old-password-1")
      assert {:ok, _} = Accounts.sign_in_with_password(email, "new-password-1")

      # Code: the old one is spent, the new one works.
      assert rejection(reset(email, old_code)).reason == :incorrect
      assert {:ok, _} = reset(email, new_code, "third-password-1")
    end

    test "matching ignores case, hyphens and spaces, and accepts O/0 and I/L/1" do
      {email, user} = register!()
      put_known_code!(user, "0123-4567-89AB-CDEF-GH1K")

      assert {:ok, again} = reset(email, "o123 4567 89ab cdef ghik")
      put_known_code!(again, "0123-4567-89AB-CDEF-GH1K")
      assert {:ok, again} = reset(email, "O1234567-89abCDEF-GHlK", "another-pass-2")
      put_known_code!(again, "0123-4567-89AB-CDEF-GH1K")
      assert {:ok, _} = reset(String.upcase(email), "0I23-4567-89AB-CDEF-GHLK", "third-pass-3")
    end

    test "wrong code, unknown email, guest and code-less user all get the same error after one bcrypt" do
      {email, _user} = register!()
      guest = Accounts.register_as_guest!()
      {no_code_email, no_code_user} = register!()
      clear_code!(no_code_user)

      attempts = [
        wrong_code: {email, RecoveryCode.generate()},
        unknown_email: {unique_email(), RecoveryCode.generate()},
        guest: {to_string(guest.email), RecoveryCode.generate()},
        no_code: {no_code_email, RecoveryCode.generate()}
      ]

      errors =
        for {label, {attempt_email, code}} <- attempts do
          {result, bcrypt_ops} = count_bcrypt(fn -> reset(attempt_email, code) end)
          error = rejection(result)

          assert bcrypt_ops == 1, "#{label}: expected 1 bcrypt operation, got #{bcrypt_ops}"
          assert error.reason == :incorrect
          RecoveryRejected.text(error)
        end

      assert errors |> Enum.uniq() |> length() == 1
      assert hd(errors) == "email or recovery code is incorrect"
    end

    test "after 5 failures in the window further attempts are rejected without bcrypt" do
      {email, user} = register!("old-password-1")
      code = user.__metadata__.recovery_code

      for _ <- 1..5,
          do: assert(rejection(reset(email, RecoveryCode.generate())).reason == :incorrect)

      # Even the correct code is refused, and nothing is hashed or verified.
      {result, bcrypt_ops} = count_bcrypt(fn -> reset(String.upcase(email), code) end)
      assert rejection(result).reason == :throttled
      assert bcrypt_ops == 0
      assert RecoveryRejected.text(rejection(result)) =~ "too many attempts"

      # Sign-in is not throttled, and the password did not change.
      assert {:ok, _} = Accounts.sign_in_with_password(email, "old-password-1")

      # Other emails are unaffected.
      {other_email, other} = register!()
      assert {:ok, _} = reset(other_email, other.__metadata__.recovery_code)
    end

    test "unknown emails are throttled too" do
      email = unique_email()
      for _ <- 1..5, do: rejection(reset(email, RecoveryCode.generate()))

      assert rejection(reset(email, RecoveryCode.generate())).reason == :throttled
    end

    test "a successful reset clears the failure count" do
      {email, user} = register!()

      for _ <- 1..4, do: rejection(reset(email, RecoveryCode.generate()))
      {:ok, reset_user} = reset(email, user.__metadata__.recovery_code)

      for _ <- 1..4, do: rejection(reset(email, RecoveryCode.generate()))
      assert {:ok, _} = reset(email, reset_user.__metadata__.recovery_code, "another-pass-2")
    end

    test "invalid input is rejected before the code is checked and changes nothing" do
      {email, user} = register!("old-password-1")
      code = user.__metadata__.recovery_code

      {result, bcrypt_ops} =
        count_bcrypt(fn -> reset(email, code, "new-password-1", "different-password") end)

      assert {:error, %Ash.Error.Invalid{}} = result
      assert bcrypt_ops == 0
      assert {:error, %Ash.Error.Invalid{}} = reset(email, code, "short")
      assert RecoveryThrottle.allowed?(email)

      assert {:ok, _} = Accounts.sign_in_with_password(email, "old-password-1")
      assert {:ok, _} = reset(email, code)
    end
  end

  describe "regenerate_recovery_code" do
    test "requires the current password and invalidates the old code" do
      {email, user} = register!("old-password-1")
      old_code = user.__metadata__.recovery_code
      old_hash = reload!(user).hashed_recovery_code

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.regenerate_recovery_code(user, "wrong-password")

      assert reload!(user).hashed_recovery_code == old_hash

      {:ok, regenerated} = Accounts.regenerate_recovery_code(user, "old-password-1")
      new_code = regenerated.__metadata__.recovery_code

      assert Regex.match?(@code_format, new_code)
      refute new_code == old_code
      assert rejection(reset(email, old_code)).reason == :incorrect
      assert {:ok, _} = reset(email, new_code)
    end

    test "rejects guests without crashing" do
      guest = Accounts.register_as_guest!()

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.regenerate_recovery_code(guest, "anything-at-all")

      assert Exception.message(error) =~ "register an account"
      assert reload!(guest).hashed_recovery_code == nil
    end

    test "rejects an account without a password without crashing" do
      user = Ash.create!(User, %{email: unique_email()}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.regenerate_recovery_code(user, "anything-at-all")

      assert Exception.message(error) =~ "no password"
    end

    test "lets an account that predates codes set one up" do
      {email, user} = register!("old-password-1")
      clear_code!(user)

      {:ok, regenerated} = Accounts.regenerate_recovery_code(reload!(user), "old-password-1")

      assert {:ok, _} = reset(email, regenerated.__metadata__.recovery_code)
    end
  end

  describe "RecoveryThrottle" do
    test "keys are trimmed and lowercased" do
      email = unique_email()
      now = System.monotonic_time(:millisecond)

      for _ <- 1..5, do: RecoveryThrottle.record_failure("  " <> String.upcase(email), now)

      refute RecoveryThrottle.allowed?(email, now)
      RecoveryThrottle.clear(email)
      assert RecoveryThrottle.allowed?(email, now)
    end

    test "failures expire after the window and are swept" do
      email = unique_email()
      t0 = System.monotonic_time(:millisecond)
      window = RecoveryThrottle.window_ms()

      for _ <- 1..5, do: RecoveryThrottle.record_failure(email, t0)

      refute RecoveryThrottle.allowed?(email, t0 + window - 1)
      assert RecoveryThrottle.allowed?(email, t0 + window)

      assert RecoveryThrottle.sweep(t0 + window) >= 1
      assert :ets.lookup(RecoveryThrottle, RecoveryThrottle.key(email)) == []
    end

    test "the window slides: old failures stop counting one by one" do
      email = unique_email()
      t0 = System.monotonic_time(:millisecond)
      window = RecoveryThrottle.window_ms()

      for i <- 0..4, do: RecoveryThrottle.record_failure(email, t0 + i * 1000)

      refute RecoveryThrottle.allowed?(email, t0 + 4000)
      assert RecoveryThrottle.allowed?(email, t0 + window)
      RecoveryThrottle.record_failure(email, t0 + window)
      refute RecoveryThrottle.allowed?(email, t0 + window)
    end
  end

  describe "change_password and stored tokens" do
    # The log_out_everywhere add-on's own password-change hook never fires for
    # :change_password (its `changing(:hashed_password)` condition is checked
    # before the non-atomic HashPasswordChange sets the hash), so the action
    # revokes explicitly (OnPasswordChange as an action change).
    test "changing the password revokes every previously stored token" do
      {email, user} = register!("old-password-1")

      {:ok, %{__metadata__: %{token: token}}} =
        Accounts.sign_in_with_password(email, "old-password-1")

      assert verifies?(token)

      {:ok, _} =
        Accounts.change_password(user, %{
          current_password: "old-password-1",
          password: "new-password-1",
          password_confirmation: "new-password-1"
        })

      refute verifies?(token)
      refute verifies?(user.__metadata__.token)
    end

    test "a failed password change revokes nothing" do
      {email, user} = register!("old-password-1")

      {:ok, %{__metadata__: %{token: token}}} =
        Accounts.sign_in_with_password(email, "old-password-1")

      assert {:error, _} =
               Accounts.change_password(user, %{
                 current_password: "wrong-password-1",
                 password: "new-password-1",
                 password_confirmation: "new-password-1"
               })

      assert verifies?(token)
      assert verifies?(user.__metadata__.token)
    end
  end
end
