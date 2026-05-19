defmodule Scrawly.Games.LobbyChatServer do
  @moduledoc """
  In-memory store for lobby chat messages. Holds the most recent messages
  in GenServer state so they survive page refreshes while the node is up,
  and wipes them every Sunday 00:00:00 UTC.
  """
  use GenServer

  require Logger

  @max_messages 200

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Append a message to the in-memory log. `message` is a plain map with
  string keys, ready to be pushed to clients as-is.
  """
  def add_message(message) when is_map(message) do
    GenServer.cast(__MODULE__, {:add_message, message})
  end

  @doc """
  Return the persisted messages oldest-first.
  """
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
    {:ok, %{messages: []}}
  end

  @impl true
  def handle_cast({:add_message, message}, state) do
    messages = [message | state.messages] |> Enum.take(@max_messages)
    {:noreply, %{state | messages: messages}}
  end

  @impl true
  def handle_call(:list_messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  def handle_call(:clear_chat, _from, state) do
    ScrawlyWeb.Endpoint.broadcast("lobby:rooms", "chat_cleared", %{})
    {:reply, :ok, %{state | messages: []}}
  end

  @impl true
  def handle_info(:clear_chat, state) do
    ScrawlyWeb.Endpoint.broadcast("lobby:rooms", "chat_cleared", %{})
    schedule_next_run()
    {:noreply, %{state | messages: []}}
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
