defmodule Scrawly.Games.LobbyChatServerTest do
  @moduledoc """
  The lobby chat's store and producer: per-sender rate limit, struct-free
  lines, and the `:lobby` Realtime broadcasts, seen on Hologram.PubSub as the
  SSE connections see them. The server is global, hence `async: false`.
  """
  use ExUnit.Case, async: false

  import Scrawly.RoomTestHelpers, only: [struct_free?: 1]

  alias Scrawly.Games.LobbyChatServer

  setup do
    on_exit(fn -> LobbyChatServer.clear_chat() end)
    Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(:lobby))
    LobbyChatServer.clear_chat()
    # clear_chat's own broadcast
    assert_receive {:broadcast_action, :lobby, :lobby_chat_cleared, _, _}

    %{key: "TEST-sender-#{System.unique_integer([:positive])}"}
  end

  defp line(text, name \\ "TESTname"), do: %{username: name, message: text, is_guest: false}

  test "stores a struct-free line and broadcasts it to the lobby", %{key: key} do
    assert {:ok, line} = LobbyChatServer.add_message(key, line("  TEST hi  ", "TESTann"))

    assert %{username: "TESTann", message: "TEST hi", is_guest: false} = line
    assert is_integer(line.id)
    assert {:ok, _dt, 0} = DateTime.from_iso8601(line.timestamp)
    assert Map.keys(line) |> Enum.sort() == [:id, :is_guest, :message, :timestamp, :username]
    assert struct_free?(line)

    assert_receive {:broadcast_action, :lobby, :lobby_chat_received, ^line, []}
    assert LobbyChatServer.list_messages() == [line]
  end

  test "trims, cuts to 240 characters, rejects blank text without counting it", %{key: key} do
    assert {:error, :empty} = LobbyChatServer.add_message(key, line("   "))
    assert {:error, :empty} = LobbyChatServer.add_message(key, line(nil))

    long = String.duplicate("é", 300)
    assert {:ok, %{message: message}} = LobbyChatServer.add_message(key, line(long))
    assert String.length(message) == 240

    refute_receive {:broadcast_action, :lobby, :lobby_chat_received, %{message: ""}, _}
  end

  test "4 lines per 5 s per sender; rejected lines don't count; other senders unaffected",
       %{key: key} do
    {max, window} = LobbyChatServer.rate_limit()
    assert {max, window} == {4, 5_000}

    for i <- 1..4 do
      assert {:ok, _} = LobbyChatServer.add_message(key, line("TEST #{i}"), 1_000 + i)
    end

    assert {:error, :rate_limited} = LobbyChatServer.add_message(key, line("TEST 5"), 2_000)
    assert {:error, :rate_limited} = LobbyChatServer.add_message(key, line("TEST 6"), 6_000)
    assert {:ok, _} = LobbyChatServer.add_message("#{key}-other", line("TEST other"), 2_000)

    # The window slides: the first line (t = 1001) has left it at 6001.
    assert {:ok, _} = LobbyChatServer.add_message(key, line("TEST 7"), 6_001)
    assert {:error, :rate_limited} = LobbyChatServer.add_message(key, line("TEST 8"), 6_001)

    texts = LobbyChatServer.list_messages() |> Enum.map(& &1.message)
    assert texts == ["TEST 1", "TEST 2", "TEST 3", "TEST 4", "TEST other", "TEST 7"]
    refute "TEST 5" in texts
  end

  test "a line without a sender key is refused" do
    assert {:error, :no_sender} = LobbyChatServer.add_message(nil, line("TEST anon"))
    assert LobbyChatServer.list_messages() == []
  end

  test "keeps the newest 200 lines" do
    for i <- 1..205 do
      {:ok, _} = LobbyChatServer.add_message("TEST-k#{i}", line("TEST #{i}"))
    end

    messages = LobbyChatServer.list_messages()
    assert length(messages) == 200
    assert hd(messages).message == "TEST 6"
    assert List.last(messages).message == "TEST 205"
  end

  test "clearing (and the weekly wipe) empties the log and broadcasts :lobby_chat_cleared",
       %{key: key} do
    {:ok, _} = LobbyChatServer.add_message(key, line("TEST before"))

    :ok = LobbyChatServer.clear_chat()
    assert_receive {:broadcast_action, :lobby, :lobby_chat_cleared, %{}, []}
    assert LobbyChatServer.list_messages() == []

    {:ok, _} = LobbyChatServer.add_message("#{key}-2", line("TEST again"))
    send(Process.whereis(LobbyChatServer), :clear_chat)
    assert_receive {:broadcast_action, :lobby, :lobby_chat_cleared, %{}, []}
    assert LobbyChatServer.list_messages() == []
  end
end
