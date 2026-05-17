defmodule Scrawly.Integration.DrawingSyncTest do
  use ScrawlyWeb.ChannelCase, async: false

  alias ScrawlyWeb.GameChannel
  alias Scrawly.Games
  alias Scrawly.Games.RoomServer
  alias Scrawly.Accounts.User

  describe "drawing synchronization across multiple clients" do
    setup do
      {:ok, existing} = Games.get_all_words()
      Enum.each(existing, fn w -> Ash.destroy!(w) end)
      Scrawly.Games.Word.seed_words()

      # Create 3 players
      players =
        for i <- 1..3 do
          Ash.create!(
            User,
            %{email: "draw-p#{i}-#{System.unique_integer([:positive])}@test.com"},
            authorize?: false
          )
        end

      {:ok, room} =
        Games.create_room(%{
          max_players: 6,
          name: "Drawing Sync Test",
          creator_id: List.first(players).id
        })

      # Ensure RoomServer is started
      {:ok, _pid} = RoomServer.ensure_started(room.id)

      # Join players to room
      for p <- players do
        p
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update!()
      end

      [drawer | guessers] = players

      # Create game and start round with first player as drawer
      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, game} = Games.start_round(game.id, drawer.id)

      # Connect drawer socket
      {:ok, _, drawer_socket} =
        ScrawlyWeb.UserSocket
        |> socket("user_id", %{user_id: drawer.id})
        |> subscribe_and_join(GameChannel, "game:#{room.code}")

      # Connect guesser sockets
      guesser_sockets =
        for g <- guessers do
          {:ok, _, sock} =
            ScrawlyWeb.UserSocket
            |> socket("user_id", %{user_id: g.id})
            |> subscribe_and_join(GameChannel, "game:#{room.code}")

          {g, sock}
        end

      %{
        room: room,
        game: game,
        drawer: drawer,
        guessers: guessers,
        drawer_socket: drawer_socket,
        guesser_sockets: guesser_sockets
      }
    end

    test "drawing_segment broadcasts to all other clients", %{drawer_socket: drawer_socket} do
      ref = push(drawer_socket, "drawing_segment", %{"segment" => "M 100 200 L 150 250"})
      assert_reply ref, :ok, %{status: "segment_received"}

      assert_broadcast "drawing_segment", %{"segment" => "M 100 200 L 150 250"}
    end

    test "multiple segments accumulate in RoomServer", %{drawer_socket: drawer_socket, room: room} do
      push(drawer_socket, "drawing_segment", %{"segment" => "M 10 20"})
      push(drawer_socket, "drawing_segment", %{"segment" => " L 30 40"})
      push(drawer_socket, "drawing_segment", %{"segment" => " L 50 60"})
      push(drawer_socket, "drawing_segment", %{"segment" => " M 100 100"})
      push(drawer_socket, "drawing_segment", %{"segment" => " L 120 120"})

      Process.sleep(50)

      {:ok, state} = RoomServer.get_state(room.id)
      assert state.drawing_path == "M 10 20 L 30 40 L 50 60 M 100 100 L 120 120"
    end

    test "drawing_clear resets drawing path", %{drawer_socket: drawer_socket, room: room} do
      push(drawer_socket, "drawing_segment", %{"segment" => "M 10 20 L 30 40"})
      Process.sleep(50)

      ref = push(drawer_socket, "drawing_clear", %{})
      assert_reply ref, :ok, %{status: "drawing_cleared"}

      assert_broadcast "drawing_clear", %{}

      Process.sleep(50)
      {:ok, state} = RoomServer.get_state(room.id)
      assert state.drawing_path == ""
    end

    test "broadcast_from sends to topic but not the sender socket", %{
      drawer_socket: drawer_socket
    } do
      push(drawer_socket, "drawing_segment", %{"segment" => "M 100 150"})

      # broadcast_from sends to the topic (visible to subscribers, including test process)
      # but the sender's socket process itself is excluded
      assert_broadcast "drawing_segment", %{"segment" => "M 100 150"}
    end

    test "non-drawer client can also push drawing events (channel doesn't restrict)", %{
      guesser_sockets: [{_guesser, guesser_socket} | _]
    } do
      # The channel doesn't restrict who can draw — authorization is at the UI level
      ref = push(guesser_socket, "drawing_segment", %{"segment" => "M 10 20"})
      assert_reply ref, :ok, %{status: "segment_received"}
    end

    test "Ash game state correctly identifies current drawer", %{
      game: game,
      drawer: drawer,
      guessers: guessers
    } do
      assert game.current_drawer_id == drawer.id

      for g <- guessers do
        refute game.current_drawer_id == g.id
      end
    end

    test "get_drawing_path returns accumulated path", %{
      drawer_socket: drawer_socket
    } do
      push(drawer_socket, "drawing_segment", %{"segment" => "M 10 20 L 30 40"})
      Process.sleep(50)

      # A late-joiner would request the current path
      ref = push(drawer_socket, "get_drawing_path", %{})
      assert_reply ref, :ok, %{path: path}
      assert path =~ "M 10 20 L 30 40"
    end

    test "drawing sync works alongside chat messages", %{
      drawer_socket: drawer_socket,
      guesser_sockets: [{_guesser, guesser_socket} | _]
    } do
      push(drawer_socket, "drawing_segment", %{"segment" => "M 10 20"})
      assert_broadcast "drawing_segment", %{"segment" => "M 10 20"}

      ref = push(guesser_socket, "chat_message", %{"message" => "Is it a cat?"})
      assert_reply ref, :ok, %{status: "message_sent"}
      assert_broadcast "chat_message", %{"message" => "Is it a cat?"}

      push(drawer_socket, "drawing_segment", %{"segment" => " L 30 40"})
      assert_broadcast "drawing_segment", %{"segment" => " L 30 40"}
    end

    test "game state transitions clear drawer context between rounds", %{
      game: game,
      drawer: drawer,
      guessers: guessers
    } do
      assert game.current_drawer_id == drawer.id
      assert game.current_word != nil

      {:ok, completed} = Games.complete_round(game.id)
      assert completed.current_word == nil

      {:ok, _} = Games.next_round(game.id)
      new_drawer = List.first(guessers)
      {:ok, new_game} = Games.start_round(game.id, new_drawer.id)

      assert new_game.current_drawer_id == new_drawer.id
      assert new_game.current_word != nil
      assert new_game.current_drawer_id != drawer.id
    end
  end
end
