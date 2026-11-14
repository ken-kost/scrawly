defmodule ScrawlyWeb.OnlineTrackerTest do
  @moduledoc """
  The "N online" counter: distinct keys with a TTL, swept periodically, the
  count broadcast at most once per coalescing window. Each test runs its own
  unnamed tracker with a fake clock (`:atomics`, read inside the tracker) and
  a broadcast fun that messages the test.

  `async: false`: the last test listens on the real `:online` channel, which
  the app's tracker also uses.
  """
  use ExUnit.Case, async: false

  alias ScrawlyWeb.OnlineTracker

  defp start_tracker(opts \\ []) do
    clock = :atomics.new(1, signed: true)
    test = self()

    pid =
      start_supervised!(
        {OnlineTracker,
         Keyword.merge(
           [
             name: nil,
             clock: fn -> :atomics.get(clock, 1) end,
             broadcast: fn count -> send(test, {:online_count, count}) end,
             sweep_ms: 60_000
           ],
           opts
         )}
      )

    %{pid: pid, clock: clock}
  end

  defp set_clock(%{clock: clock}, ms), do: :atomics.put(clock, 1, ms)

  # touch/2 is a cast that reads the clock when the tracker handles it; the
  # count/1 call after it waits for that, so the clock can be moved safely.
  defp touch!(%{pid: pid}, key) do
    OnlineTracker.touch(pid, key)
    OnlineTracker.count(pid)
  end

  defp sweep(%{pid: pid}), do: send(pid, :sweep)

  test "counts distinct keys; several touches of one key count once" do
    t = start_tracker()

    touch!(t, "user-1")
    touch!(t, "user-1")
    touch!(t, "anon:abc")
    touch!(t, nil)

    assert OnlineTracker.count(t.pid) == 2
  end

  test "a key is dropped by the first sweep after the TTL, and a touch keeps it" do
    t = start_tracker()
    ttl = OnlineTracker.ttl_ms()

    touch!(t, "stays")
    touch!(t, "leaves")
    assert OnlineTracker.count(t.pid) == 2

    # A ping (every 20 s) refreshes one of them.
    set_clock(t, 20_000)
    touch!(t, "stays")

    # Exactly at the TTL a key still counts; 1 ms later the sweep drops it.
    set_clock(t, ttl)
    sweep(t)
    assert OnlineTracker.count(t.pid) == 2

    set_clock(t, ttl + 1)
    sweep(t)
    assert OnlineTracker.count(t.pid) == 1

    set_clock(t, 20_000 + ttl)
    sweep(t)
    assert OnlineTracker.count(t.pid) == 1

    set_clock(t, 20_000 + ttl + 1)
    sweep(t)
    assert OnlineTracker.count(t.pid) == 0
  end

  test "the sweep runs on its own every sweep_ms" do
    t = start_tracker(sweep_ms: 20)

    touch!(t, "k")
    assert_receive {:online_count, 1}

    set_clock(t, OnlineTracker.ttl_ms() + 1)
    assert_receive {:online_count, 0}, 500
    assert OnlineTracker.count(t.pid) == 0
  end

  test "changes are broadcast at once, then at most once per window with the latest count" do
    t = start_tracker(coalesce_ms: 200)

    touch!(t, "a")
    assert_receive {:online_count, 1}

    # Inside the window: no broadcast now, one at its end carrying 3.
    set_clock(t, 50)
    touch!(t, "b")
    touch!(t, "c")
    refute_receive {:online_count, _}, 50
    assert_receive {:online_count, 3}, 500
    refute_receive {:online_count, _}, 250

    # Touching a known key changes nothing and broadcasts nothing.
    set_clock(t, 1_000)
    touch!(t, "a")
    refute_receive {:online_count, _}, 50

    # After the window a change goes out immediately again.
    touch!(t, "d")
    assert_receive {:online_count, 4}, 50
  end

  test "a change undone inside the window sends nothing" do
    t = start_tracker(coalesce_ms: 150)

    touch!(t, "a")
    assert_receive {:online_count, 1}

    set_clock(t, 10)
    touch!(t, "b")
    # "b" expires before the window ends (the sweep drops it): back to 1.
    set_clock(t, 10 + OnlineTracker.ttl_ms() + 1)
    touch!(t, "a")
    sweep(t)
    assert OnlineTracker.count(t.pid) == 1
    refute_receive {:online_count, _}, 400
  end

  test "the default broadcast is :online_count_updated on the :online channel" do
    Phoenix.PubSub.subscribe(
      Hologram.PubSub,
      Hologram.Realtime.channel_topic(OnlineTracker.channel())
    )

    pid =
      start_supervised!({OnlineTracker, name: nil, sweep_ms: 60_000})

    OnlineTracker.touch(pid, "TEST-#{System.unique_integer([:positive])}")

    assert_receive {:broadcast_action, :online, :online_count_updated, %{count: 1}, []}
  end

  test "count/0 is 0 when the tracker isn't running" do
    assert OnlineTracker.count(:no_such_tracker) == 0
  end
end
