defmodule ScrawlyWeb.GameIntegrationTest do
  @moduledoc """
  The GameChannel admits only room members and relays live stroke chunks only
  from the current drawer while the room is `:drawing`.
  """
  use ScrawlyWeb.ChannelCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @chunk %{
    "stroke_id" => "s-1700000000000-1",
    "seq" => 1,
    "delta" => "M 10 20 L 11 21",
    "color" => "#d63838",
    "width" => 5
  }

  setup do
    creator = create_user()
    player = create_user()
    room = start_room(creator)

    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(player)).next_action.name ==
             :room_resynced

    %{room: room, creator: creator, player: player}
  end

  defp join_channel(user_id, room_code) do
    ScrawlyWeb.UserSocket
    |> socket("socket_id", %{user_id: user_id})
    |> subscribe_and_join(ScrawlyWeb.GameChannel, "game:#{room_code}")
  end

  defp join!(user, room) do
    {:ok, _reply, socket} = join_channel(user.id, room.code)
    socket
  end

  defp watch!(user, room) do
    assert GamePage.command(:join_as_watcher, %{room_id: room.id}, server_for(user)).next_action.name ==
             :room_resynced
  end

  defp chunk(attrs \\ %{}), do: Map.merge(@chunk, attrs)

  defp assert_relayed(socket, payload) do
    push(socket, "drawing_stroke_chunk", payload)
    assert_broadcast "drawing_stroke_chunk", relayed
    relayed
  end

  defp refute_relayed(socket, payload) do
    push(socket, "drawing_stroke_chunk", payload)
    refute_broadcast "drawing_stroke_chunk", _
  end

  # Moves the cached drawing verdict 2 s into the past, as if time had passed.
  defp age_verdict(socket) do
    :sys.replace_state(socket.channel_pid, fn state ->
      {id, verdict, at} = state.assigns.chunk_verdict
      Phoenix.Socket.assign(state, :chunk_verdict, {id, verdict, at - 2_001})
    end)
  end

  defp end_round!(room) do
    assert expire_round!(room).phase == :round_end
  end

  describe "join" do
    test "the creator and a player can join", %{room: room, creator: creator, player: player} do
      for user <- [creator, player] do
        assert {:ok, _reply, socket} = join_channel(user.id, room.code)
        assert socket.assigns.room_code == room.code
        assert socket.assigns.room_id == room.id
        assert socket.assigns.user_id == user.id
      end
    end

    test "a logged-in watcher can join, guests included", %{room: room} do
      watcher = create_user()
      guest = Scrawly.Accounts.register_as_guest!()

      for user <- [watcher, guest] do
        watch!(user, room)
        assert {:ok, _reply, socket} = join_channel(user.id, room.code)
        assert socket.assigns.user_id == user.id
      end
    end

    test "the same player can connect multiple times", %{room: room, player: player} do
      assert {:ok, _, _} = join_channel(player.id, room.code)
      assert {:ok, _, socket} = join_channel(player.id, room.code)
      assert socket.assigns.user_id == player.id
    end

    test "an account that is not in the room is refused", %{room: room} do
      assert {:error, %{reason: "not_member"}} = join_channel(create_user().id, room.code)

      guest = Scrawly.Accounts.register_as_guest!()
      assert {:error, %{reason: "not_member"}} = join_channel(guest.id, room.code)
    end

    test "nobody can join a room whose RoomServer is not running", ctx do
      stop_room(ctx.room.id)
      assert_room_stopped(ctx.room.id)

      assert {:error, %{reason: "not_member"}} = join_channel(ctx.creator.id, ctx.room.code)
    end

    test "an unauthenticated socket is refused", %{room: room} do
      assert {:error, %{reason: "unauthorized"}} = join_channel(nil, room.code)
    end

    test "joining an unknown room is refused", %{player: player} do
      assert {:error, %{reason: "invalid_room"}} = join_channel(player.id, "NOPE99")
    end
  end

  describe "drawing_stroke_chunk while :drawing" do
    setup %{room: room, creator: creator} do
      %{game_id: game_id} = start_drawing!(room, creator)
      %{game_id: game_id}
    end

    test "the drawer's chunk is relayed, normalized", %{room: room, creator: creator} do
      socket = join!(creator, room)

      assert assert_relayed(socket, Map.put(chunk(), "extra", "x")) == chunk()

      relayed = assert_relayed(socket, Map.drop(chunk(%{"seq" => 2}), ["color", "width"]))
      assert relayed["color"] == "#000000"
      assert relayed["width"] == 2
    end

    test "any #rrggbb colour (no preset) reaches viewers exactly: live and committed",
         %{room: room, creator: creator} do
      # The colour panel's (colors): what the wheel or the hex field gives.
      color = "#3fa7c2"
      refute color in ScrawlyWeb.Components.DrawingToolbar.colors()
      socket = join!(creator, room)

      assert assert_relayed(socket, chunk(%{"color" => color}))["color"] == color

      Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room.id}))
      stroke = %{id: "s-custom", path: "M 1 1 L 9 9", color: color, width: 7}
      :ok = RoomServer.append_drawing(room.id, creator.id, stroke)

      assert_receive {:broadcast_action, {:room, _}, :stroke_completed,
                      %{stroke_id: "s-custom", color: ^color, width: 7}, _}

      assert [%{color: ^color}] = room_state!(room.id).drawing_strokes
    end

    test "a non-drawer's chunk is not relayed", %{room: room, player: player} do
      socket = join!(player, room)
      refute_relayed(socket, chunk())

      watcher = create_user()
      watch!(watcher, room)
      refute_relayed(join!(watcher, room), chunk())
    end

    test "oversized or invalid chunks from the drawer are dropped", %{
      room: room,
      creator: creator
    } do
      socket = join!(creator, room)

      for bad <- [
            %{"delta" => String.duplicate("1", 2_001)},
            %{"delta" => ""},
            %{"delta" => nil},
            %{"delta" => 42},
            %{"delta" => " L 1 2 <script>"},
            %{"stroke_id" => String.duplicate("a", 65)},
            %{"stroke_id" => ""},
            %{"stroke_id" => 7},
            %{"seq" => "1"},
            %{"seq" => nil},
            %{"color" => "red"},
            %{"width" => 41},
            %{"width" => "5"}
          ] do
        refute_relayed(socket, chunk(bad))
      end

      assert_relayed(socket, chunk(%{"delta" => String.duplicate("1", 2_000)}))
    end

    test "an unknown event leaves the channel alive", %{room: room, creator: creator} do
      socket = join!(creator, room)

      for event <- ["nope", "chat_message", "drawing_start"] do
        push(socket, event, %{"anything" => true})
      end

      push(socket, "drawing_stroke_chunk", "not a map")

      assert assert_relayed(socket, chunk()) == chunk()
      assert Process.alive?(socket.channel_pid)
    end

    test "an :allow is cached for the stroke while the room doesn't change",
         %{room: room, creator: creator} do
      socket = join!(creator, room)
      assert_relayed(socket, chunk())

      assert {"s-1700000000000-1", :allow, _at} =
               :sys.get_state(socket.channel_pid).assigns.chunk_verdict

      assert_relayed(socket, chunk(%{"seq" => 2}))
    end

    test "the :allow doesn't outlive the drawing phase (QA G15)",
         %{room: room, creator: creator} do
      socket = join!(creator, room)
      assert_relayed(socket, chunk())

      end_round!(room)

      # Same stroke, well within 2 s: the room's change dropped the verdict.
      refute_relayed(socket, chunk(%{"seq" => 2}))
      refute_relayed(socket, chunk(%{"stroke_id" => "s-1700000000000-2"}))
    end

    test "only the newest 8 open strokes are tracked, and they are abandoned on leave",
         %{room: room, creator: creator} do
      socket = join!(creator, room)
      ids = for n <- 1..10, do: "s-#{n}"

      for id <- ids, do: assert_relayed(socket, chunk(%{"stroke_id" => id}))
      assert_relayed(socket, chunk(%{"stroke_id" => "s-5"}))

      open = :sys.get_state(socket.channel_pid).assigns.open_stroke_ids
      assert open == ["s-5", "s-10", "s-9", "s-8", "s-7", "s-6", "s-4", "s-3"]

      Process.unlink(socket.channel_pid)
      leave(socket)

      for id <- open do
        assert_broadcast "drawing_stroke_abandon", %{"stroke_id" => ^id}
      end

      refute_broadcast "drawing_stroke_abandon", _
    end
  end

  # QA G14: a drawer's socket can't flood the room with chunks.
  describe "chunk rate limit" do
    setup %{room: room, creator: creator} do
      start_drawing!(room, creator)
      :ok
    end

    test "at most 60 chunks a second per socket are relayed", %{room: room, creator: creator} do
      socket = join!(creator, room)
      for seq <- 1..61, do: push(socket, "drawing_stroke_chunk", chunk(%{"seq" => seq}))

      for seq <- 1..60, do: assert_broadcast("drawing_stroke_chunk", %{"seq" => ^seq})
      refute_broadcast "drawing_stroke_chunk", _

      # A second later the socket may send again.
      :sys.replace_state(socket.channel_pid, fn state ->
        Phoenix.Socket.assign(
          state,
          :chunk_times,
          Enum.map(state.assigns.chunk_times, &(&1 - 1_000))
        )
      end)

      assert_relayed(socket, chunk(%{"seq" => 62}))
    end
  end

  describe "drawing_stroke_chunk outside :drawing" do
    test "the drawer's chunk is not relayed while choosing; the denial is cached for 2 s", ctx do
      {:ok, _started} =
        RoomServer.start_game(ctx.room.id, ctx.creator.id, %{word_choices: choices(["zz"])})

      socket = join!(ctx.creator, ctx.room)
      refute_relayed(socket, chunk())

      # Denied recently and nothing changed: dropped without asking the room.
      assert {_id, :deny, _at} = :sys.get_state(socket.channel_pid).assigns.chunk_verdict
      refute_relayed(socket, chunk(%{"stroke_id" => "s-other"}))

      age_verdict(socket)
      refute_relayed(socket, chunk(%{"stroke_id" => "s-other"}))
    end

    test "a denial from :choosing is lifted as soon as the word is committed", ctx do
      {:ok, _started} =
        RoomServer.start_game(ctx.room.id, ctx.creator.id, %{word_choices: choices(["zz"])})

      socket = join!(ctx.creator, ctx.room)
      refute_relayed(socket, chunk())

      {:ok, %{phase: :drawing}} = RoomServer.choose_word(ctx.room.id, ctx.creator.id, "zz")

      assert_relayed(socket, chunk(%{"stroke_id" => "s-other"}))
    end

    test "the drawer's chunk is not relayed after time is up", ctx do
      start_drawing!(ctx.room, ctx.creator)
      end_round!(ctx.room)

      refute_relayed(join!(ctx.creator, ctx.room), chunk())
    end

    test "no chunk is relayed in the lobby", %{room: room, creator: creator} do
      refute_relayed(join!(creator, room), chunk())
    end
  end
end
