defmodule Scrawly.Accounts.RecoveryThrottle do
  @moduledoc """
  In-memory limit on recovery-code resets: at most 5 failed attempts per
  normalized email in a sliding 15-minute window. Unknown emails count too, so
  the limit says nothing about whether an account exists.

  Reads go straight to a named ETS table; writes are serialized through this
  process. State is lost on restart (the app runs on a single machine).
  Password sign-in is not throttled here.
  """

  use GenServer

  @table __MODULE__
  @max_failures 5
  @window_ms :timer.minutes(15)
  @sweep_every_ms :timer.minutes(5)

  # ── API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The maximum number of failures allowed per window."
  def max_failures, do: @max_failures

  @doc "The window length in milliseconds."
  def window_ms, do: @window_ms

  @doc "The throttle key for an email: trimmed and lowercased."
  @spec key(term) :: String.t()
  def key(email), do: email |> to_string() |> String.trim() |> String.downcase()

  @doc "True while `email` has fewer than #{@max_failures} failures in the window."
  @spec allowed?(term, integer) :: boolean
  def allowed?(email, now \\ now()) do
    length(recent(key(email), now)) < @max_failures
  end

  @doc "Records one failed attempt for `email`."
  @spec record_failure(term, integer) :: :ok
  def record_failure(email, now \\ now()),
    do: GenServer.call(__MODULE__, {:record_failure, key(email), now})

  @doc "Forgets every failure for `email` (after a successful reset)."
  @spec clear(term) :: :ok
  def clear(email), do: GenServer.call(__MODULE__, {:clear, key(email)})

  @doc false
  def sweep(now \\ now()), do: GenServer.call(__MODULE__, {:sweep, now})

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_call({:record_failure, key, now}, _from, state) do
    stamps = [now | recent(key, now)] |> Enum.take(@max_failures)
    :ets.insert(@table, {key, now, stamps})
    {:reply, :ok, state}
  end

  def handle_call({:clear, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  def handle_call({:sweep, now}, _from, state) do
    {:reply, do_sweep(now), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep(now())
    schedule_sweep()
    {:noreply, state}
  end

  # ── Internals ────────────────────────────────────────────────────────

  # Failure timestamps for `key` that are still inside the window, newest first.
  defp recent(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, _newest, stamps}] -> Enum.filter(stamps, &(now - &1 < @window_ms))
      [] -> []
    end
  end

  # Drops every key whose newest failure has left the window.
  defp do_sweep(now) do
    cutoff = now - @window_ms
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:"=<", :"$1", cutoff}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
