defmodule Scrawly.Games.PayloadLimitsTest do
  @moduledoc """
  QA G2: user text is capped by BYTES as well as by characters wherever it is
  stored or broadcast. A character count alone lets one grapheme ("a"
  followed by thousands of combining marks) weigh megabytes.

    * Room chat and lobby chat: trimmed, then cut to 240 characters AND
      1,000 bytes at a grapheme boundary; a line whose first grapheme alone
      is over the byte cap leaves nothing (`:empty`).
    * Usernames (20 characters, 80 bytes), emails (254 bytes), room names
      (40 characters, 160 bytes) and prompts (200 characters, 800 bytes) are
      validated on every action that writes them; the avatar id must look
      like one of the preset ids.
    * Names that reach a room from older rows are cut to the username caps.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.{LobbyChatServer, RoomServer}
  alias ScrawlyWeb.LobbyChat
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  # One grapheme of 1 + 2n bytes: "a" and n combining acute accents (U+0301).
  defp heavy(n), do: "a" <> String.duplicate("́", n)

  defp graphemes(text), do: String.length(text)

  describe "room chat" do
    setup do
      creator = create_user()
      player = create_user()
      room = start_room(creator)
      {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})
      %{room: room, player: player}
    end

    test "240 heavy characters are cut to at most 1,000 bytes, at a grapheme boundary",
         %{room: room, player: player} do
      Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room.id}))
      # 41 bytes a grapheme, 9,840 bytes in all.
      text = String.duplicate(heavy(20), 240)

      assert {:ok, :chat} = RoomServer.submit_message(room.id, player.id, text)

      [line | _] = room_state!(room.id).chat_messages
      assert byte_size(line.message) <= 1_000
      # As many whole graphemes as fit: 24 (984 bytes).
      assert line.message == String.duplicate(heavy(20), 24)

      assert_receive {:broadcast_action, {:room, _}, :chat_appended, %{message: sent}, []}
      assert sent.message == line.message
    end

    test "a single grapheme over the byte cap leaves nothing to send",
         %{room: room, player: player} do
      before = room_state!(room.id).chat_messages
      # 1 character, 1.2 MB.
      assert {:error, :empty} =
               RoomServer.submit_message(room.id, player.id, "  " <> heavy(600_000))

      assert room_state!(room.id).chat_messages == before
    end

    test "trailing whitespace left by the cut is trimmed", %{room: room, player: player} do
      # 943 bytes, a space, then an 81-byte grapheme that doesn't fit.
      text = String.duplicate(heavy(20), 23) <> " " <> heavy(40)

      assert {:ok, :chat} = RoomServer.submit_message(room.id, player.id, text)

      assert hd(room_state!(room.id).chat_messages).message ==
               String.duplicate(heavy(20), 23)
    end

    test "invalid UTF-8 is empty", %{room: room, player: player} do
      assert {:error, :empty} = RoomServer.submit_message(room.id, player.id, <<0xFF, 0xFE>>)
    end
  end

  describe "lobby chat" do
    setup do
      on_exit(fn -> LobbyChatServer.clear_chat() end)
      LobbyChatServer.clear_chat()
      %{key: "TEST-g2-#{System.unique_integer([:positive])}"}
    end

    test "a stored line is at most 240 characters and 1,000 bytes", %{key: key} do
      text = String.duplicate(heavy(20), 240)

      assert {:ok, %{message: message}} =
               LobbyChatServer.add_message(key, %{
                 username: "TESTg2",
                 message: text,
                 is_guest: false
               })

      assert byte_size(message) <= 1_000
      assert message == String.duplicate(heavy(20), 24)
      assert graphemes(String.duplicate("é", 300) |> LobbyChatServer.clean_message()) == 240
    end

    test "a single oversized grapheme sends nothing", %{key: key} do
      assert {:error, :empty} =
               LobbyChatServer.add_message(key, %{
                 username: "TESTg2",
                 message: heavy(600_000),
                 is_guest: false
               })

      assert LobbyChatServer.clean_message(<<0xFF>>) == ""
    end

    test "the home page command stores the capped line" do
      Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(:lobby))
      server = anon_server("g2-lobby-#{System.unique_integer([:positive])}")

      LobbyChat.send_message(%{message: String.duplicate(heavy(20), 240)}, server)

      assert_receive {:broadcast_action, :lobby, :lobby_chat_received, %{message: message}, _}
      assert byte_size(message) <= 1_000

      LobbyChat.send_message(%{message: heavy(600_000)}, server)
      refute_receive {:broadcast_action, :lobby, :lobby_chat_received, _, _}, 50
    end

    test "a display name over the caps is cut before it is stored", %{key: key} do
      assert {:ok, %{username: name}} =
               LobbyChatServer.add_message(key, %{
                 username: String.duplicate(heavy(20), 20),
                 message: "TEST hi",
                 is_guest: false
               })

      assert byte_size(name) <= 80
    end
  end

  describe "usernames, emails and avatars" do
    # 20 characters, 140 bytes.
    @heavy_name String.duplicate("é́́", 20)

    test "update_profile rejects a 20-character username over 80 bytes" do
      user = create_user()

      assert {:error, error} = Accounts.update_profile(user, %{username: @heavy_name})
      assert Enum.any?(error.errors, &(Map.get(&1, :field) == :username))

      assert {:ok, %{username: "TEST_twenty_chars_ok"}} =
               Accounts.update_profile(user, %{username: "TEST_twenty_chars_ok"})

      # 20 characters of 4 bytes is the most that fits.
      assert {:ok, _} = Accounts.update_profile(user, %{username: String.duplicate("😀", 20)})
    end

    test "create and join_room reject it too" do
      n = System.unique_integer([:positive])

      assert {:error, _} =
               Ash.create(
                 Accounts.User,
                 %{email: "test-g2-#{n}@example.com", username: @heavy_name},
                 authorize?: false
               )

      creator = create_user()
      room = start_room(creator)
      user = create_user()

      assert {:error, _} =
               user
               |> Ash.Changeset.for_update(:join_room, %{
                 current_room_id: room.id,
                 username: @heavy_name
               })
               |> Ash.update(authorize?: false)
    end

    test "a username generated from a heavy email stays within the caps" do
      # 20 characters of 11 bytes before the "@" (232 bytes in all).
      local = String.duplicate(heavy(5), 20)

      assert {:ok, user} =
               Accounts.register_with_password("#{local}@example.com", "password1234",
                 authorize?: false
               )

      assert byte_size(user.username) <= 80
      assert String.length(user.username) >= 2
      assert String.starts_with?(local, user.username)
    end

    test "an email over 254 bytes is rejected" do
      email = String.duplicate("a", 250) <> "@example.com"

      assert {:error, _} =
               Accounts.register_with_password(email, "password1234", authorize?: false)
    end

    test "the avatar id must look like a preset id" do
      user = create_user()

      assert {:error, _} =
               Accounts.update_profile(user, %{avatar_id: String.duplicate("x", 5_000)})

      assert {:error, _} = Accounts.update_profile(user, %{avatar_id: "a-pizza<script>"})

      assert {:ok, %{avatar_id: "a-pizza"}} =
               Accounts.update_profile(user, %{avatar_id: "a-pizza"})
    end

    test "a name from an older, oversized row is cut when it joins a room" do
      creator = create_user()
      room = start_room(creator)
      user = create_user()

      Scrawly.Repo.query!("UPDATE users SET username = $1 WHERE id = $2", [
        String.duplicate(heavy(20), 20),
        Ecto.UUID.dump!(user.id)
      ])

      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
               :room_resynced

      player = Enum.find(room_state!(room.id).players, &(&1.id == user.id))
      assert byte_size(player.username) <= 80
      assert String.starts_with?(String.duplicate(heavy(20), 20), player.username)

      watcher = create_user()

      Scrawly.Repo.query!("UPDATE users SET username = $1 WHERE id = $2", [
        String.duplicate(heavy(20), 20),
        Ecto.UUID.dump!(watcher.id)
      ])

      assert GamePage.command(:join_as_watcher, %{room_id: room.id}, server_for(watcher)).next_action.name ==
               :room_resynced

      [w] = room_state!(room.id).watchers
      assert byte_size(w.username) <= 80
    end
  end

  describe "rooms" do
    test "create rejects a name over 160 bytes and a prompt over 800 bytes" do
      creator = create_user()
      base = %{max_players: 4, creator_id: creator.id}

      # 40 characters, 280 bytes.
      assert {:error, _} =
               Games.create_room(Map.put(base, :name, String.duplicate(heavy(3), 40)))

      # 200 characters, 1,400 bytes.
      assert {:error, _} =
               Games.create_room(
                 Map.merge(base, %{
                   name: "TEST g2",
                   word_source: :ai,
                   prompt: String.duplicate(heavy(3), 200)
                 })
               )

      assert {:ok, _} =
               Games.create_room(
                 Map.merge(base, %{name: "TEST g2 ok", prompt: String.duplicate("é", 200)})
               )
    end
  end
end
