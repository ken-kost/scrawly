defmodule Scrawly.Accounts.Throttle do
  @moduledoc """
  In-memory sliding-window limits on the attempts that cost a bcrypt check or
  create rows: password sign-in, recovery-code resets and guest accounts.

  An attempt is counted *before* it runs: `reserve/2` checks every bucket the
  attempt touches and records it in all of them in one call to this process,
  so parallel requests can never get past a limit (check-then-record would let
  every request in flight through). A sign-in or reset that succeeds hands its
  slots back (`release/1`); failed attempts keep theirs until they leave the
  window.

  | policy            | key                  | limit           |
  | ----------------- | -------------------- | --------------- |
  | `:sign_in_email`  | `email_key/1`        | 10 per 15 min   |
  | `:sign_in_ip`     | client IP            | 50 per 15 min   |
  | `:recovery_email` | `email_key/1`        | 5 per 15 min    |
  | `:recovery_ip`    | client IP            | 20 per 15 min   |
  | `:guest_ip`       | client IP            | 20 per 10 min   |

  Email buckets are keyed by the database's own lowercasing (`email_key/1`):
  the `email` column is citext, so every spelling the account lookup treats as
  the same address shares one bucket. Unknown emails count too, so a limit
  never tells whether an account exists. A `nil` key (no client IP known)
  skips that bucket.

  Writes go through this process; the protected ETS table lets `attempts/3`
  read without a call. State is lost on restart (the app runs on one machine).
  """

  use GenServer

  @table __MODULE__
  @sweep_every_ms :timer.minutes(5)

  @policies %{
    sign_in_email: {10, :timer.minutes(15)},
    sign_in_ip: {50, :timer.minutes(15)},
    recovery_email: {5, :timer.minutes(15)},
    recovery_ip: {20, :timer.minutes(15)},
    guest_ip: {20, :timer.minutes(10)}
  }

  @type policy :: :sign_in_email | :sign_in_ip | :recovery_email | :recovery_ip | :guest_ip
  @type bucket :: {policy, term}
  @typedoc "The slots one attempt took, for `release/1`."
  @opaque ticket :: [{bucket, integer}]

  # ── API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`{max_attempts, window_ms}` of `policy`."
  @spec limit(policy) :: {pos_integer, pos_integer}
  def limit(policy), do: Map.fetch!(@policies, policy)

  @doc """
  Counts one attempt in every bucket (`{policy, key}`; `nil` keys are skipped)
  if all of them are under their limit, atomically. `{:error, :throttled}`
  records nothing.
  """
  @spec reserve([bucket], integer) :: {:ok, ticket} | {:error, :throttled}
  def reserve(buckets, now \\ now()) do
    buckets = for {policy, key} <- buckets, key != nil, do: {policy, key}
    Enum.each(buckets, fn {policy, _key} -> limit(policy) end)
    GenServer.call(__MODULE__, {:reserve, buckets, now})
  end

  @doc "Hands back the slots of a successful attempt."
  @spec release(ticket) :: :ok
  def release(ticket) when is_list(ticket), do: GenServer.call(__MODULE__, {:release, ticket})

  @doc "Forgets every attempt in one bucket."
  @spec clear(policy, term) :: :ok
  def clear(policy, key), do: GenServer.call(__MODULE__, {:clear, {policy, key}})

  @doc "Attempts still counted in one bucket."
  @spec attempts(policy, term, integer) :: non_neg_integer
  def attempts(policy, key, now \\ now()) do
    {_max, window} = limit(policy)
    length(recent({policy, key}, window, now))
  end

  @doc """
  The bucket key for an email: trimmed and lowercased by the database, i.e.
  exactly as the citext `email` column compares it (Elixir's
  `String.downcase/1` disagrees for letters such as "İ"). Non-strings key as "".
  """
  @spec email_key(term) :: String.t()
  def email_key(%Ash.CiString{} = email), do: email |> to_string() |> email_key()

  def email_key(email) when is_binary(email) do
    email = String.trim(email)

    case Scrawly.Repo.query("SELECT lower($1::text)", [email]) do
      {:ok, %{rows: [[key]]}} when is_binary(key) -> key
      _ -> String.downcase(email)
    end
  end

  def email_key(_email), do: ""

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
  def handle_call({:reserve, buckets, now}, _from, state) do
    full? =
      Enum.any?(buckets, fn {policy, _key} = bucket ->
        {max, window} = limit(policy)
        length(recent(bucket, window, now)) >= max
      end)

    if full? do
      {:reply, {:error, :throttled}, state}
    else
      ticket =
        Enum.map(buckets, fn {policy, _key} = bucket ->
          {_max, window} = limit(policy)
          id = System.unique_integer([:positive, :monotonic])
          :ets.insert(@table, {bucket, now + window, [{now, id} | recent(bucket, window, now)]})
          {bucket, id}
        end)

      {:reply, {:ok, ticket}, state}
    end
  end

  def handle_call({:release, ticket}, _from, state) do
    Enum.each(ticket, fn {bucket, id} ->
      case :ets.lookup(@table, bucket) do
        [{^bucket, expires_at, stamps}] ->
          :ets.insert(@table, {bucket, expires_at, List.keydelete(stamps, id, 1)})

        [] ->
          :ok
      end
    end)

    {:reply, :ok, state}
  end

  def handle_call({:clear, bucket}, _from, state) do
    :ets.delete(@table, bucket)
    {:reply, :ok, state}
  end

  def handle_call({:sweep, now}, _from, state), do: {:reply, do_sweep(now), state}

  @impl true
  def handle_info(:sweep, state) do
    do_sweep(now())
    schedule_sweep()
    {:noreply, state}
  end

  # ── Internals ────────────────────────────────────────────────────────

  # Stamps of `bucket` still inside the window, newest first.
  defp recent(bucket, window, now) do
    case :ets.lookup(@table, bucket) do
      [{^bucket, _expires_at, stamps}] ->
        Enum.filter(stamps, fn {at, _id} -> now - at < window end)

      [] ->
        []
    end
  end

  # Drops every bucket whose newest attempt has left its window.
  defp do_sweep(now) do
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:"=<", :"$1", now}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
