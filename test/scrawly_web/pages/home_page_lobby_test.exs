defmodule ScrawlyWeb.Pages.HomePageLobbyTest do
  @moduledoc """
  The home page's room list and lobby chat over Hologram Realtime (`:lobby`):
  init loads both and subscribes, the broadcasts update the lists in place,
  and `:send_lobby_chat` names the sender on the server (a guest_N nickname
  kept in the session for account-less visitors).
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers

  alias Hologram.{Component, Server}
  alias Scrawly.Accounts
  alias Scrawly.Games.{LobbyChatServer, RoomServer}
  alias ScrawlyWeb.Pages.HomePage

  @moduletag :capture_log

  setup do
    LobbyChatServer.clear_chat()
    on_exit(fn -> LobbyChatServer.clear_chat() end)
    Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(:lobby))
    :ok
  end

  # What a HomePage command receives: the page's middleware has run.
  defp page_server(%Server{} = server), do: run_page_middleware(HomePage, server)

  defp anon_page_server(session \\ %{}),
    do: page_server(%{anon_server(session_id()) | session: session})

  defp session_id, do: "TEST-session-#{System.unique_integer([:positive])}"

  defp send_chat(server, message),
    do: HomePage.command(:send_lobby_chat, %{message: message}, server)

  defp page(state), do: %Component{state: state}

  defp room(id, players \\ 1) do
    %{
      room_id: id,
      name: "TEST #{id}",
      code: "C#{id}",
      status: :lobby,
      max_players: 4,
      word_source: :local,
      round_duration: 60,
      round_multiplier: 1,
      players: List.duplicate(%{avatar_id: "a1", avatar_color: "2"}, players)
    }
  end

  defp line(id, text \\ "TEST"),
    do: %{
      id: id,
      username: "TESTu",
      message: text,
      is_guest: false,
      timestamp: "2026-11-14T00:00:00Z"
    }

  describe "init/3" do
    test "loads the lobby rooms as summaries and the chat, subscribes to :lobby; no socket token" do
      creator = create_user()
      room = start_room(creator, %{name: "TEST init room"})

      {:ok, line} =
        LobbyChatServer.add_message("TEST-k", %{username: "TESTx", message: "TEST hi"})

      server = signed_in_server(creator)
      {component, server} = HomePage.init(%{}, %Component{}, server)

      assert Enum.any?(server.subscriptions, &(elem(&1, 0) == :lobby))
      refute Map.has_key?(component.state, :socket_token)

      summary = Enum.find(component.state.rooms, &(&1.room_id == room.id))
      assert summary == RoomServer.lobby_summary(:sys.get_state(pid_of(room)))
      assert Enum.all?(component.state.rooms, &(map_size(&1) == 11))
      assert component.state.lobby_chat_messages == [line]
      assert component.state.page_shown? == false
      assert struct_free?(component.state)
    end

    test "keeps the newest 100 chat lines, newest first" do
      for i <- 1..120 do
        {:ok, _} =
          LobbyChatServer.add_message("TEST-k#{i}", %{username: "TESTx", message: "TEST #{i}"})
      end

      {component, _server} = HomePage.init(%{}, %Component{}, anon_page_server())
      messages = component.state.lobby_chat_messages

      assert length(messages) == 100
      assert hd(messages).message == "TEST 120"
      assert List.last(messages).message == "TEST 21"
    end
  end

  describe "room list broadcasts" do
    test ":lobby_room_changed replaces a known room in place and appends a new one" do
      component = page(%{rooms: [room("a"), room("b")]})

      updated = HomePage.action(:lobby_room_changed, %{room: room("a", 3)}, component)

      assert Enum.map(updated.state.rooms, &{&1.room_id, length(&1.players)}) == [
               {"a", 3},
               {"b", 1}
             ]

      added = HomePage.action(:lobby_room_changed, %{room: room("c")}, updated)
      assert Enum.map(added.state.rooms, & &1.room_id) == ["a", "b", "c"]
    end

    test ":lobby_room_removed drops the room; an unknown id changes nothing" do
      component = page(%{rooms: [room("a"), room("b")]})

      assert HomePage.action(:lobby_room_removed, %{room_id: "a"}, component).state.rooms == [
               room("b")
             ]

      assert HomePage.action(:lobby_room_removed, %{room_id: "zz"}, component) == component
    end
  end

  describe "chat broadcasts" do
    test ":lobby_chat_received prepends the line once, keeping 100" do
      component = page(%{lobby_chat_messages: [line(2), line(1)]})

      result = HomePage.action(:lobby_chat_received, line(3, "TEST new"), component)
      assert Enum.map(result.state.lobby_chat_messages, & &1.id) == [3, 2, 1]

      assert HomePage.action(:lobby_chat_received, line(2), component) == component

      full = page(%{lobby_chat_messages: Enum.map(100..1//-1, &line/1)})
      capped = HomePage.action(:lobby_chat_received, line(101), full).state.lobby_chat_messages
      assert length(capped) == 100
      assert hd(capped).id == 101
      assert List.last(capped).id == 2
    end

    test ":lobby_chat_cleared empties the chat" do
      component = page(%{lobby_chat_messages: [line(1)]})
      assert HomePage.action(:lobby_chat_cleared, %{}, component).state.lobby_chat_messages == []
    end
  end

  describe "sending" do
    test ":send_lobby_chat clears the input and sends the trimmed text; blank sends nothing" do
      component = page(%{lobby_chat_input: "  TEST hello  ", lobby_chat_notice: "old"})
      result = HomePage.action(:send_lobby_chat, %{event: %{}}, component)

      assert result.state.lobby_chat_input == ""
      assert result.state.lobby_chat_notice == nil
      assert %{name: :send_lobby_chat, params: %{message: "TEST hello"}} = result.next_command

      blank = page(%{lobby_chat_input: "   ", lobby_chat_notice: nil})
      assert HomePage.action(:send_lobby_chat, %{event: %{}}, blank) == blank
    end

    test "a signed-in user's line carries the account's username" do
      user = create_user()
      result = send_chat(signed_in_server(user), "  TEST from a user ")

      assert result.next_action == nil
      assert session_puts(result) |> Map.has_key?("guest_nickname") == false

      assert_receive {:broadcast_action, :lobby, :lobby_chat_received,
                      %{username: username, message: "TEST from a user", is_guest: false}, []}

      assert username == user.username
    end

    test "a guest account chats under its own username" do
      guest = Accounts.register_as_guest!()
      send_chat(signed_in_server(guest), "TEST guest account")

      assert_receive {:broadcast_action, :lobby, :lobby_chat_received,
                      %{username: username, is_guest: false}, _}

      assert username == guest.username
    end

    test "an account-less visitor gets a guest_N name, kept in the session" do
      server = anon_page_server()
      result = send_chat(server, "TEST first")

      assert %{"guest_nickname" => nickname} = session_puts(result)
      assert nickname =~ ~r/\Aguest_\d+\z/

      assert_receive {:broadcast_action, :lobby, :lobby_chat_received,
                      %{username: ^nickname, is_guest: true, message: "TEST first"}, _}

      # The next request with the same cookie: same name, no new session write.
      next = page_server(%{server | session: result.session, __meta__: %Server.Metadata{}})
      again = send_chat(next, "TEST second")

      assert session_puts(again) == %{}
      assert_receive {:broadcast_action, :lobby, :lobby_chat_received, %{username: ^nickname}, _}
    end

    test "the client can't choose the name" do
      server = anon_page_server(%{"guest_nickname" => "System"})

      result =
        HomePage.command(
          :send_lobby_chat,
          %{
            message: "TEST forged",
            username: "System",
            guest_nickname: "System",
            is_guest: false
          },
          server
        )

      assert %{"guest_nickname" => nickname} = session_puts(result)
      assert nickname =~ ~r/\Aguest_\d+\z/

      assert_receive {:broadcast_action, :lobby, :lobby_chat_received,
                      %{username: ^nickname, is_guest: true}, _}
    end

    test "a blank message does nothing" do
      server = anon_page_server()
      assert send_chat(server, "   ") == server
      assert send_chat(server, nil) == server
      assert LobbyChatServer.list_messages() == []
    end

    test "the fifth line within 5 s from one session is rejected with its text" do
      server = anon_page_server(%{"guest_nickname" => "guest_42"})

      for i <- 1..4, do: assert(send_chat(server, "TEST #{i}").next_action == nil)

      result = send_chat(server, " TEST 5 ")

      assert %{name: :lobby_chat_rejected, params: %{reason: :rate_limited, message: "TEST 5"}} =
               result.next_action

      assert LobbyChatServer.list_messages() |> Enum.map(& &1.message) ==
               ["TEST 1", "TEST 2", "TEST 3", "TEST 4"]

      # Another session isn't limited by it.
      assert send_chat(anon_page_server(), "TEST other").next_action == nil
    end

    test ":lobby_chat_rejected puts the text back and shows a notice that clears itself" do
      component =
        page(%{lobby_chat_input: "", lobby_chat_notice: nil, lobby_chat_notice_gen: 3})

      result =
        HomePage.action(
          :lobby_chat_rejected,
          %{reason: :rate_limited, message: "TEST 5"},
          component
        )

      assert result.state.lobby_chat_input == "TEST 5"
      assert result.state.lobby_chat_notice =~ "slow down"

      assert %{name: :clear_lobby_chat_notice, params: %{gen: 4}, delay: 4_000} =
               result.next_action

      # Typed again meanwhile: the new text stays.
      typing = put_in(component.state.lobby_chat_input, "TEST newer")

      assert HomePage.action(:lobby_chat_rejected, %{reason: :rate_limited, message: "x"}, typing).state.lobby_chat_input ==
               "TEST newer"

      cleared = HomePage.action(:clear_lobby_chat_notice, %{gen: 4}, result)
      assert cleared.state.lobby_chat_notice == nil

      stale = HomePage.action(:clear_lobby_chat_notice, %{gen: 3}, result)
      assert stale.state.lobby_chat_notice == result.state.lobby_chat_notice
    end
  end

  describe "Back/Forward restore" do
    test "the first :page_shown only marks the page; a later one resyncs" do
      component = page(%{page_shown?: false})

      first = HomePage.action(:page_shown, %{mount_id: "1"}, component)
      assert first.state.page_shown? == true
      assert first.next_command == nil

      {again, calls} =
        Scrawly.JsCallTrace.js_calls(fn ->
          HomePage.action(:page_shown, %{mount_id: "1"}, first)
        end)

      # Server-side, JS.call returns :ok (no stale rooms list).
      assert %{name: :resync_lobby, params: %{stale_rooms: []}} = again.next_command
      # The demo board gets the tool the restored toolbar shows.
      assert calls == [
               connectDemoBoard: [%{color: "#000000", width: 2, eraser: false}],
               takeStaleRoomChannels: [nil]
             ]

      red_eraser =
        put_in(first.state, Map.merge(first.state, %{demo_color: "#d63838", demo_eraser: true}))

      {_again, calls} =
        Scrawly.JsCallTrace.js_calls(fn ->
          HomePage.action(:page_shown, %{mount_id: "1"}, red_eraser)
        end)

      assert {:connectDemoBoard, [%{color: "#d63838", width: 2, eraser: true}]} in calls
    end

    test ":resync_lobby re-subscribes and replies with both lists" do
      creator = create_user()
      room = start_room(creator)

      {:ok, line} =
        LobbyChatServer.add_message("TEST-k", %{username: "TESTx", message: "TEST hi"})

      result = HomePage.command(:resync_lobby, %{}, anon_page_server())

      assert Enum.any?(result.subscriptions, &(elem(&1, 0) == :lobby))

      assert %{name: :lobby_resynced, params: %{rooms: rooms, messages: [^line]}} =
               result.next_action

      assert Enum.any?(rooms, &(&1.room_id == room.id))

      applied =
        HomePage.action(
          :lobby_resynced,
          result.next_action.params,
          page(%{rooms: [], lobby_chat_messages: []})
        )

      assert applied.state.rooms == rooms
      assert applied.state.lobby_chat_messages == [line]
    end
  end

  describe "the lobby channel is gone" do
    test "no LobbyChannel, Presence, lobby socket or room polling left in lib" do
      for path <- [
            "lib/scrawly_web/channels/lobby_channel.ex",
            "lib/scrawly_web/channels/presence.ex",
            "lib/scrawly_web/pages/lobby_channel.mjs"
          ] do
        refute File.exists?(path), path
      end

      sources =
        Path.wildcard("lib/**/*.{ex,mjs,js}")
        |> Enum.map(&{&1, File.read!(&1)})

      for needle <- [
            "lobby:rooms",
            "LobbyChannel",
            "ScrawlyWeb.Presence",
            "refresh_rooms",
            "tick_online",
            "read_online_count",
            "connectLobbyChannel",
            "list_active_rooms"
          ],
          {path, source} <- sources do
        refute source =~ needle, "#{path} still mentions #{inspect(needle)}"
      end

      refute File.read!("lib/scrawly_web/pages/home_page.ex") =~ "socket_token"
    end
  end

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end
end
