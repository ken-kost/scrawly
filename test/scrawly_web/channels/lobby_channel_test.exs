defmodule ScrawlyWeb.LobbyChannelTest do
  @moduledoc """
  Lobby chat is open to visitors without an account. Their name comes from the
  client's `guest_nickname` only when it looks like one the client generates
  (`guest_<digits>`); anything else gets a server-generated `guest_N`, so
  nobody can chat as "System" or as a registered player.

  LobbyChatServer and Presence are global, hence `async: false`.
  """
  use ScrawlyWeb.ChannelCase, async: false

  import Scrawly.RoomTestHelpers, only: [create_user: 0]

  alias Scrawly.Games.LobbyChatServer
  alias ScrawlyWeb.LobbyChannel

  @generated ~r/\Aguest_\d+\z/

  setup do
    on_exit(fn -> LobbyChatServer.clear_chat() end)
    :ok
  end

  defp join_lobby(user_id, payload) do
    {:ok, _reply, socket} =
      ScrawlyWeb.UserSocket
      |> socket(nil, %{user_id: user_id})
      |> subscribe_and_join(LobbyChannel, "lobby:rooms", payload)

    socket
  end

  defp chat_name(socket), do: socket.assigns.chat_username

  test "an anonymous socket claiming \"System\" chats as a generated guest_N" do
    socket = join_lobby(nil, %{"guest_nickname" => "System"})

    ref = push(socket, "chat_message", %{"message" => "hello"})
    assert_reply ref, :ok, %{status: "sent"}

    assert_broadcast "chat_message", %{"username" => name, "is_guest" => true}
    assert name =~ @generated
    assert name == chat_name(socket)
  end

  test "nicknames that are not guest_<digits> are replaced" do
    registered = create_user()

    for nick <- [
          "System",
          " system ",
          registered.username,
          "guest_",
          "guest_abc",
          "guest_12345678901",
          "guest_12 34",
          "guest_12\nSystem",
          "Guest_12",
          "",
          42,
          nil,
          %{"name" => "guest_1"}
        ] do
      name = chat_name(join_lobby(nil, %{"guest_nickname" => nick}))

      assert name =~ @generated, "#{inspect(nick)} gave #{inspect(name)}"
      refute name == nick
    end

    assert chat_name(join_lobby(nil, %{})) =~ @generated
  end

  test "a client-generated guest_<digits> nickname is kept (trimmed)" do
    assert chat_name(join_lobby(nil, %{"guest_nickname" => "guest_4821"})) == "guest_4821"
    assert chat_name(join_lobby(nil, %{"guest_nickname" => " guest_77 "})) == "guest_77"
  end

  test "a signed-in socket chats under its account's username, whatever it claims" do
    user = create_user()
    socket = join_lobby(user.id, %{"guest_nickname" => "System"})

    assert chat_name(socket) == user.username
  end
end
