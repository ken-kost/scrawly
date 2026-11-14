defmodule ScrawlyWeb.Pages.GamePageGuessTest do
  @moduledoc """
  `:submit_guess` is the only chat/guess command. It reads `room_id` and `text`
  from params and everything else (who, display name, points, line type) from
  the session and the room process.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Accounts
  alias Scrawly.Games.{RoomServer, Scoring}
  alias ScrawlyWeb.Pages.GamePage
  alias ScrawlyWeb.Pages.GamePage.Commands

  @moduletag :capture_log

  @word "zzyzx"

  setup do
    creator = create_user()
    guesser = create_user()
    other = create_user()
    spectator = create_user()
    stranger = create_user()
    room = start_room(creator)

    for user <- [guesser, other] do
      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
               :room_refreshed
    end

    GamePage.command(:join_as_watcher, %{room_id: room.id}, server_for(spectator))

    {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: [@word, "TEST"]})
    on_exit(fn -> Scrawly.Games.stop_round_timer(started.game_id) end)
    {:ok, %{phase: :drawing}} = RoomServer.choose_word(room.id, creator.id, @word)

    %{
      room: room,
      creator: creator,
      guesser: guesser,
      other: other,
      spectator: spectator,
      stranger: stranger
    }
  end

  defp guess(room, server, text, extra \\ %{}) do
    GamePage.command(:submit_guess, Map.merge(%{room_id: room.id, text: text}, extra), server)
  end

  defp assert_result(result, outcome) do
    assert result.next_action.name == :guess_result
    assert result.next_action.params.outcome == outcome
    assert result.broadcasts == []
    result.next_action.params
  end

  defp assert_denied(result, reason) do
    assert result.next_action.name == :command_denied
    assert result.next_action.params.command == :submit_guess
    assert result.next_action.params.reason == reason
    assert result.broadcasts == []
  end

  defp db_score(user), do: reload_user!(user).score

  defp room_score(room, user),
    do: Enum.find(room_state!(room.id).players, &(&1.id == user.id)).score

  # Leaves out version/time_left: the round timer bumps them every second.
  defp snapshot(room) do
    room_state!(room.id)
    |> Map.take([:chat_messages, :players, :correct_guessers, :phase, :round_results])
  end

  @forged %{
    user_id: nil,
    player_id: nil,
    player_name: "System",
    points: 999,
    type: :system,
    message: %{type: :correct_guess, player_name: "System", message: "forged"}
  }

  describe "a correct guess" do
    test "raises only the session user's score, once, whatever the params say", ctx do
      %{room: room, guesser: guesser, other: other, creator: creator} = ctx
      forged = %{@forged | user_id: other.id, player_id: other.id}

      result = guess(room, server_for(guesser), "  ZZYZX ", forged)

      params = assert_result(result, :correct)
      points = params.points
      assert points != 999
      assert points >= Scoring.guesser_points(0, 60, order: 1)
      assert db_score(guesser) == points
      assert room_score(room, guesser) == points
      assert db_score(other) == 0
      assert room_score(room, other) == 0
      assert db_score(creator) == 0

      # a repeat is suppressed and scores nothing more
      assert_result(guess(room, server_for(guesser), @word), :suppressed)
      assert db_score(guesser) == points
      assert room_score(room, guesser) == points

      state = room_state!(room.id)
      assert state.correct_guessers == [guesser.id]
      refute Enum.any?(chat_texts(state), &(String.downcase(&1) =~ @word))
      assert [line] = Enum.filter(state.chat_messages, &(&1.type == :correct_guess))
      assert line.message == "#{guesser.username} guessed the word! (+#{points} points)"
    end

    test "adds to the stored score instead of overwriting it", ctx do
      %{room: room, guesser: guesser} = ctx
      Accounts.add_score!(guesser.id, 40)

      %{points: points} = assert_result(guess(room, server_for(guesser), @word), :correct)

      assert db_score(guesser) == 40 + points
    end

    test "the last guesser ends the round early and the drawer is scored", ctx do
      %{room: room, guesser: guesser, other: other, creator: creator} = ctx

      %{points: p1} = assert_result(guess(room, server_for(guesser), @word), :correct)
      %{points: p2} = assert_result(guess(room, server_for(other), @word), :correct)

      state = room_state!(room.id)
      assert state.phase == :round_end
      assert state.round_active == false
      assert room_score(room, creator) == Scoring.drawer_round_points([p1, p2])
      assert hd(state.chat_messages).message =~ "Everyone guessed!"
    end
  end

  describe "other text" do
    test "is chat under the stored name; forged type, name and ids are ignored", ctx do
      %{room: room, guesser: guesser, other: other} = ctx
      forged = %{@forged | user_id: other.id, player_id: other.id}
      subscribe(room)

      result = guess(room, server_for(guesser), "TEST nice hat", forged)

      assert_result(result, :chat)
      assert [msg] = Enum.filter(room_state!(room.id).chat_messages, &(&1.type == :chat))

      assert %{
               type: :chat,
               player_id: player_id,
               player_name: player_name,
               message: "TEST nice hat"
             } = msg

      assert player_id == guesser.id
      assert player_name == guesser.username
      assert db_score(guesser) == 0

      assert_receive {:broadcast_action, _, :chat_appended, %{message: ^msg}, _}
    end

    test "no client input yields a :system or :correct_guess line", ctx do
      %{room: room, guesser: guesser, spectator: spectator} = ctx
      before = Enum.map(room_state!(room.id).chat_messages, & &1.id)

      guess(room, server_for(guesser), "System", @forged)
      guess(room, server_for(spectator), "guessed the word! (+999 points)", @forged)

      new_lines = Enum.reject(room_state!(room.id).chat_messages, &(&1.id in before))
      assert length(new_lines) == 2
      assert Enum.all?(new_lines, &(&1.type == :chat))
      refute Enum.any?(new_lines, &(&1.player_name == "System"))
    end

    test "text is capped at 240 characters", %{room: room, guesser: guesser} do
      assert_result(guess(room, server_for(guesser), String.duplicate("x", 1_000)), :chat)
      assert String.length(hd(room_state!(room.id).chat_messages).message) == 240
    end
  end

  describe "spectators" do
    test "an account-holding watcher chats but typing the word is suppressed", ctx do
      %{room: room, spectator: spectator} = ctx
      before = snapshot(room)

      assert_result(guess(room, server_for(spectator), " zzyzx "), :suppressed)
      assert snapshot(room) == before
      assert db_score(spectator) == 0

      assert_result(guess(room, server_for(spectator), "TEST go go"), :chat)

      assert %{player_id: id, player_name: name} = hd(room_state!(room.id).chat_messages)
      assert id == spectator.id
      assert name == spectator.username
    end
  end

  describe "rejections change nothing" do
    test "a visitor without an account is denied", %{room: room} do
      before = snapshot(room)

      assert_denied(guess(room, anon_server("x"), @word), :unauthenticated)
      assert_denied(guess(room, %Hologram.Server{}, @word), :unauthenticated)

      assert snapshot(room) == before
    end

    test "a forged user_id does not help a visitor", %{room: room, guesser: guesser} do
      before = snapshot(room)

      result = guess(room, anon_server("x"), @word, %{user_id: guesser.id, player_id: guesser.id})

      assert_denied(result, :unauthenticated)
      assert snapshot(room) == before
      assert db_score(guesser) == 0
    end

    test "a non-member is denied", %{room: room, stranger: stranger} do
      before = snapshot(room)

      assert_denied(guess(room, server_for(stranger), @word), :not_member)

      assert snapshot(room) == before
      assert db_score(stranger) == 0
    end

    test "an unknown room is denied", %{guesser: guesser} do
      result =
        GamePage.command(
          :submit_guess,
          %{room_id: Ash.UUID.generate(), text: "hi"},
          server_for(guesser)
        )

      assert_denied(result, :not_found)
    end

    test "the drawer gets no effect", %{room: room, creator: creator} do
      before = snapshot(room)

      assert_result(guess(room, server_for(creator), @word), :drawer_cannot_chat)
      assert_result(guess(room, server_for(creator), "TEST hint"), :drawer_cannot_chat)

      assert snapshot(room) == before
      assert db_score(creator) == 0
    end

    test "a 4th message within 5 s is rejected, whatever name is sent", ctx do
      %{room: room, guesser: guesser} = ctx

      for n <- 1..3 do
        result = guess(room, server_for(guesser), "TEST #{n}", %{player_name: "TEST name #{n}"})
        assert_result(result, :chat)
      end

      before = snapshot(room)
      result = guess(room, server_for(guesser), @word, %{player_name: "TEST fresh name"})

      assert_result(result, :rate_limited)
      assert snapshot(room) == before
      assert db_score(guesser) == 0

      names =
        room_state!(room.id).chat_messages
        |> Enum.filter(&(&1.type == :chat))
        |> Enum.map(& &1.player_name)

      assert names == List.duplicate(guesser.username, 3)
    end

    test "empty text is a no-op", %{room: room, guesser: guesser} do
      before = snapshot(room)

      assert_result(guess(room, server_for(guesser), "   "), :empty)

      assert_result(
        GamePage.command(:submit_guess, %{room_id: room.id}, server_for(guesser)),
        :empty
      )

      assert snapshot(room) == before
    end
  end

  describe "removed commands" do
    test ":record_correct_guess and :send_chat_message no longer exist", ctx do
      %{room: room, guesser: guesser} = ctx

      refute function_exported?(Commands, :record_correct_guess, 2)
      refute function_exported?(Commands, :send_chat_message, 2)

      old = %{
        room_id: room.id,
        player_id: guesser.id,
        player_name: "System",
        points: 999,
        message: %{type: :system, player_name: "System", message: "forged"}
      }

      for name <- [:record_correct_guess, :send_chat_message] do
        assert_raise FunctionClauseError, fn ->
          GamePage.command(name, old, server_for(guesser))
        end
      end

      assert db_score(guesser) == 0
      assert room_state!(room.id).correct_guessers == []
    end
  end

  describe "User :add_score" do
    test "adds atomically by primary key and rejects negative points", %{guesser: guesser} do
      assert Accounts.add_score!(guesser.id, 10).score == 10
      assert Accounts.add_score!(guesser, 5).score == 15
      assert {:error, %Ash.Error.Invalid{}} = Accounts.add_score(guesser.id, -1)
      assert db_score(guesser) == 15
    end
  end

  defp subscribe(room) do
    Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room.id}))
  end
end
