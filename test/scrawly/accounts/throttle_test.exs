defmodule Scrawly.Accounts.ThrottleTest do
  @moduledoc """
  `Scrawly.Accounts.Throttle`: attempts are reserved atomically across all of
  an attempt's buckets, before the attempt runs; successes hand their slots
  back; the window slides; email buckets use the database's citext
  lowercasing (QA auth #6 / T6).
  """
  use Scrawly.DataCase, async: false

  require Ash.Query

  alias Scrawly.Accounts
  alias Scrawly.Accounts.{Throttle, User}

  defp key(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "reserve/2" do
    test "counts attempts up to the limit, then refuses without recording" do
      {max, _window} = Throttle.limit(:recovery_email)
      email = key("reserve")
      now = System.monotonic_time(:millisecond)

      for _ <- 1..max, do: assert({:ok, _} = Throttle.reserve([{:recovery_email, email}], now))

      assert Throttle.reserve([{:recovery_email, email}], now) == {:error, :throttled}
      assert Throttle.attempts(:recovery_email, email, now) == max
    end

    test "is all-or-nothing across buckets: a full bucket records nothing in the others" do
      {ip_max, _} = Throttle.limit(:recovery_ip)
      ip = key("ip")
      now = System.monotonic_time(:millisecond)

      for i <- 1..ip_max,
          do:
            {:ok, _} =
              Throttle.reserve([{:recovery_email, key("e#{i}")}, {:recovery_ip, ip}], now)

      email = key("fresh")

      assert Throttle.reserve([{:recovery_email, email}, {:recovery_ip, ip}], now) ==
               {:error, :throttled}

      assert Throttle.attempts(:recovery_email, email, now) == 0
    end

    test "a nil key skips its bucket" do
      email = key("nil-ip")
      assert {:ok, ticket} = Throttle.reserve([{:sign_in_email, email}, {:sign_in_ip, nil}])
      assert [{{:sign_in_email, ^email}, _id}] = ticket
    end

    test "parallel reservations never exceed the limit" do
      {max, _window} = Throttle.limit(:recovery_email)
      email = key("parallel")

      results =
        1..(max * 4)
        |> Enum.map(fn _ ->
          Task.async(fn -> Throttle.reserve([{:recovery_email, email}]) end)
        end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, _}, &1)) == max
      assert Enum.count(results, &(&1 == {:error, :throttled})) == max * 3
    end

    test "an unknown policy raises in the caller, not in the throttle process" do
      assert_raise KeyError, fn -> Throttle.reserve([{:nope, "x"}]) end
      assert Process.alive?(Process.whereis(Throttle))
    end
  end

  describe "release/1, clear/2 and the window" do
    test "release hands back exactly the slots of one attempt" do
      email = key("release")
      now = System.monotonic_time(:millisecond)
      {:ok, _first} = Throttle.reserve([{:sign_in_email, email}], now)
      {:ok, second} = Throttle.reserve([{:sign_in_email, email}], now)

      Throttle.release(second)
      assert Throttle.attempts(:sign_in_email, email, now) == 1

      Throttle.clear(:sign_in_email, email)
      assert Throttle.attempts(:sign_in_email, email, now) == 0
    end

    test "attempts leave the window one by one and are swept" do
      {max, window} = Throttle.limit(:recovery_email)
      email = key("window")
      t0 = System.monotonic_time(:millisecond)

      for i <- 0..(max - 1), do: {:ok, _} = Throttle.reserve([{:recovery_email, email}], t0 + i)

      assert Throttle.reserve([{:recovery_email, email}], t0 + max) == {:error, :throttled}
      assert {:ok, _} = Throttle.reserve([{:recovery_email, email}], t0 + window)
      assert Throttle.reserve([{:recovery_email, email}], t0 + window) == {:error, :throttled}

      assert Throttle.sweep(t0 + 2 * window + max) >= 1
      assert Throttle.attempts(:recovery_email, email, t0 + 2 * window + max) == 0
    end
  end

  describe "email_key/1 (T6)" do
    test "agrees with the citext lookup, including letters Elixir lowercases differently" do
      n = System.unique_integer([:positive])
      email = "victim#{n}@example.com"
      {:ok, user} = Accounts.register_with_password(email, "password123")

      # "İ" (U+0130) lowercases to "i̇" in Elixir but to "i" in the database.
      variants = [
        String.replace(email, "i", "İ", global: false),
        String.replace(email, "i", "I", global: false),
        String.replace(email, "c", "C"),
        "  " <> String.upcase(email) <> " "
      ]

      for variant <- variants do
        assert Throttle.email_key(variant) == Throttle.email_key(email), variant

        found =
          User
          |> Ash.Query.for_read(:get_by_email, %{email: String.trim(variant)})
          |> Ash.read_one(authorize?: false)

        assert {:ok, %User{id: id}} = found
        assert id == user.id
      end
    end

    test "accepts Ash.CiString and keys non-strings as an empty string" do
      assert Throttle.email_key(Ash.CiString.new("A@B.c")) == "a@b.c"
      assert Throttle.email_key(nil) == ""
      assert Throttle.email_key(%{}) == ""
    end
  end
end
