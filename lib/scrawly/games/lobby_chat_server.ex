defmodule Scrawly.Games.LobbyChatServer do
  @moduledoc """
  The home page's lobby chat. Holds the most recent 200 lines in memory, so
  they survive page loads while the node is up, and wipes them every Sunday
  00:00:00 UTC.

  It is also the chat's only producer on the `:lobby` Hologram Realtime
  channel (`Scrawly.Games.RoomServer.Broadcasts.lobby_channel/0`):
  `:lobby_chat_received` with the stored line, `:lobby_chat_cleared` after a
  wipe. One process stores and broadcasts, so every home page sees the lines
  in the same order, and the sender sees its own line through the same
  broadcast as everyone else.

  Lines are plain, struct-free maps (they reach the browser as is):
  `%{id, username, message, is_guest, timestamp}`, `timestamp` an ISO 8601
  string. Each sender key (`ScrawlyWeb.Auth.actor_key/1`) may post 4 lines
  per 5 s (`rate_limit/0`).
  """
  use GenServer

  alias Scrawly.Games.RoomServer.Broadcasts

  @max_messages 200
  @max_length 240
  @chat_max_messages 4
  @chat_window_ms 5_000

  @type message :: %{
          id: pos_integer,
          username: String.t(),
          message: String.t(),
          is_guest: boolean,
          timestamp: String.t()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores and broadcasts a line from `sender_key` (the rate-limit key, never
  shown). `fields` carries the display `username`, the `message` text and
  `is_guest`. The text is trimmed and cut to #{@max_length} characters.

  `{:error, :empty}` for a blank text, `{:error, :rate_limited}` past
  #{@chat_max_messages} lines in #{@chat_window_ms} ms for that key (rejected
  lines don't count), `{:error, :no_sender}` without a key. `now` is
  monotonic ms (for tests).
  """
  @spec add_message(term, map, integer) ::
          {:ok, message} | {:error, :empty | :rate_limited | :no_sender}
  def add_message(sender_key, fields, now \\ System.monotonic_time(:millisecond))

  def add_message(nil, _fields, _now), do: {:error, :no_sender}

  def add_message(sender_key, %{username: username, message: text} = fields, now)
      when is_binary(username) and is_integer(now) do
    case clean_message(text) do
      "" ->
        {:error, :empty}

      text ->
        line = %{username: username, message: text, is_guest: Map.get(fields, :is_guest) == true}
        GenServer.call(__MODULE__, {:add_message, sender_key, line, now})
    end
  end

  @doc "Trims `text` and cuts it to #{@max_length} characters; `\"\"` for non-strings."
  @spec clean_message(term) :: String.t()
  def clean_message(text) when is_binary(text),
    do: text |> String.trim() |> String.slice(0, @max_length)

  def clean_message(_text), do: ""

  @doc "Lines per window and the window in ms of the per-sender rate limit."
  @spec rate_limit() :: {pos_integer, pos_integer}
  def rate_limit, do: {@chat_max_messages, @chat_window_ms}

  @doc """
  Return the persisted messages oldest-first.
  """
  @spec list_messages() :: [message]
  def list_messages do
    GenServer.call(__MODULE__, :list_messages)
  end

  @doc """
  Drop all stored messages and notify connected clients.
  """
  def clear_chat do
    GenServer.call(__MODULE__, :clear_chat)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    schedule_next_run()
    {:ok, %{messages: [], rate: %{}}}
  end

  @impl true
  def handle_call({:add_message, sender_key, line, now}, _from, state) do
    rate = prune_rate(state.rate, now)
    recent = Map.get(rate, sender_key, [])

    if length(recent) >= @chat_max_messages do
      {:reply, {:error, :rate_limited}, %{state | rate: rate}}
    else
      message =
        Map.merge(line, %{
          id: System.unique_integer([:positive, :monotonic]),
          timestamp: DateTime.utc_now(:second) |> DateTime.to_iso8601()
        })

      Hologram.Realtime.broadcast_action(
        Broadcasts.lobby_channel(),
        :lobby_chat_received,
        message
      )

      {:reply, {:ok, message},
       %{
         state
         | messages: Enum.take([message | state.messages], @max_messages),
           rate: Map.put(rate, sender_key, [now | recent])
       }}
    end
  end

  def handle_call(:list_messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  def handle_call(:clear_chat, _from, state) do
    broadcast_cleared()
    {:reply, :ok, %{state | messages: []}}
  end

  @impl true
  def handle_info(:clear_chat, state) do
    broadcast_cleared()
    schedule_next_run()
    {:noreply, %{state | messages: []}}
  end

  defp broadcast_cleared,
    do: Hologram.Realtime.broadcast_action(Broadcasts.lobby_channel(), :lobby_chat_cleared)

  # Keeps only the timestamps inside the window, and only senders that have
  # one, so the map holds just the recent senders.
  defp prune_rate(rate, now) do
    Enum.reduce(rate, %{}, fn {key, stamps}, acc ->
      case Enum.filter(stamps, &(now - &1 < @chat_window_ms)) do
        [] -> acc
        recent -> Map.put(acc, key, recent)
      end
    end)
  end

  # Scheduling helpers

  defp schedule_next_run do
    Process.send_after(self(), :clear_chat, ms_until_next_sunday_midnight_utc())
  end

  @doc false
  def ms_until_next_sunday_midnight_utc(now \\ DateTime.utc_now()) do
    next = next_sunday_midnight_utc(now)
    DateTime.diff(next, now, :millisecond)
  end

  @doc false
  def next_sunday_midnight_utc(now) do
    # `Date.day_of_week/2` with :sunday as the week start: Sun=1..Sat=7
    days_until_sunday =
      case Date.day_of_week(DateTime.to_date(now), :sunday) do
        1 -> 7
        n -> 8 - n
      end

    target_date = Date.add(DateTime.to_date(now), days_until_sunday)
    {:ok, target} = DateTime.new(target_date, ~T[00:00:00], "Etc/UTC")
    target
  end
end
