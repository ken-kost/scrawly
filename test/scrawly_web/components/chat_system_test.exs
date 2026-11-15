defmodule ScrawlyWeb.Components.ChatSystemTest do
  @moduledoc """
  Comprehensive unit tests for the chat system.

  Tests the chat-related actions on GamePage: message submission (the server
  checks guesses via :submit_guess), rate limiting, system messages, and
  message history management. Chat lines arrive one by one as sequenced
  `:chat_appended` broadcasts (a line's id is its seq) and as a whole in
  `:room_resynced` snapshots.
  Since Hologram actions are pure functions on %Component{} structs, we test
  them directly without needing a running server.
  """
  use ExUnit.Case, async: true

  alias Scrawly.Games.RoomServer
  alias Scrawly.Games.RoomServer.View
  alias ScrawlyWeb.Pages.GamePage

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp base_component(overrides \\ %{}) do
    defaults = %{
      room_code: "ABCD",
      current_user_id: "user-1",
      current_user_username: "Alice",
      players: [
        %{id: "user-1", username: "Alice", score: 0},
        %{id: "user-2", username: "Bob", score: 0},
        %{id: "user-3", username: "Charlie", score: 0}
      ],
      game_id: "game-1",
      game_started: true,
      round: 1,
      total_rounds: 5,
      current_drawer: %{id: "user-2", name: "Bob"},
      current_word: nil,
      current_word_display: "_ _ _ _ _ _ _ _ _",
      word_length: 9,
      revealed_word: nil,
      phase: :drawing,
      time_left: 60,
      is_drawer: false,
      is_creator: true,
      creator_id: "user-1",
      last_seq: 0,
      delta_seq: 0,
      strokes_seq: 0,
      pending_private: nil,
      resync_requested_at: nil,
      resync_owed_seq: nil,
      stuck_seq: nil,
      phase_entered_at: nil,
      restoring?: false,
      max_players: 4,
      watchers: [],
      past_games: [],
      drawing_strokes: [],
      word_choices: [],
      round_remaining_ms: 0,
      choice_remaining_ms: 0,
      choice_duration: 15,
      round_duration: 60,
      choice_time_left: 0,
      round_deadline_local: nil,
      choice_deadline_local: nil,
      zero_since: nil,
      tick_gen: 1,
      last_tick_at: nil,
      socket_token: "",
      channel_connected: false,
      channel_connecting: false,
      new_message: "",
      chat_messages: [],
      correct_guessers: [],
      used_words: [],
      rate_limited: false,
      message_timestamps: [],
      can_start_game: true,
      watching?: false,
      leaving?: false,
      room_status: :playing,
      room_name: "Room ABCD",
      drawing_path: "",
      drawing_sent_length: 0
    }

    # room_id is the page param, so a prop (never state).
    %Hologram.Component{props: %{room_id: "test-room"}, state: Map.merge(defaults, overrides)}
  end

  # The client sends only the room and the typed text; the server decides
  # whether it is a guess, who sent it and what it is worth.
  defp assert_submits(result, text) do
    assert %{name: :submit_guess, params: params} = result.next_command
    assert params == %{room_id: "test-room", text: text}
  end

  # ── 1. Message Submission Flow ──────────────────────────────────────────

  describe "send_message — basic submission" do
    test "clears input and sends message via command (not added locally)" do
      comp = base_component(%{new_message: "hello everyone"})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.new_message == ""
      # Messages go through the server, not added to local state
      assert result.state.chat_messages == []
      assert_submits(result, "hello everyone")
    end

    test "ignores empty messages" do
      comp = base_component(%{new_message: "   "})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.chat_messages == []
      # input NOT cleared on empty message
      assert result.state.new_message == "   "
    end

    test "ignores fully empty string" do
      comp = base_component(%{new_message: ""})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.chat_messages == []
    end

    test "drawer is blocked from sending chat" do
      comp =
        base_component(%{
          new_message: "nice guess!",
          is_drawer: true,
          current_drawer: %{id: "user-1", name: "Alice"}
        })

      result = GamePage.action(:send_message, %{}, comp)

      # Drawer cannot send messages - input is just cleared
      assert result.state.new_message == ""
      assert result.state.chat_messages == []
    end

    test "already-guessed player can send regular chat via command" do
      comp =
        base_component(%{
          new_message: "I already got it",
          correct_guessers: ["user-1"]
        })

      result = GamePage.action(:send_message, %{}, comp)

      # Message goes to server via command, not added locally
      assert result.state.new_message == ""
      assert result.state.chat_messages == []
      assert_submits(result, "I already got it")
    end
  end

  # ── 2. Guesses Are Checked On The Server ────────────────────────────────

  describe "send_message — guesses go to the server" do
    test "the word is sent as plain text, not matched locally" do
      comp = base_component(%{new_message: "butterfly", time_left: 60})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.new_message == ""
      assert_submits(result, "butterfly")
      # no optimistic guesser entry: :room_delta carries correct_guessers
      assert result.state.correct_guessers == []
      assert result.state.chat_messages == []
    end

    test "case and whitespace variants are sent as typed" do
      for text <- ["BUTTERFLY", "  butterfly  "] do
        result = GamePage.action(:send_message, %{}, base_component(%{new_message: text}))
        assert_submits(result, text)
        assert result.state.correct_guessers == []
      end
    end

    test "no player id, name, points or type are sent" do
      comp = base_component(%{new_message: "butterfly", time_left: 80})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.next_command.params |> Map.keys() |> Enum.sort() == [:room_id, :text]
    end

    test "does not update the local player score" do
      comp = base_component(%{new_message: "butterfly", time_left: 60})
      result = GamePage.action(:send_message, %{}, comp)

      alice = Enum.find(result.state.players, &(&1.id == "user-1"))
      assert alice.score == 0
    end

    test "drawer is blocked from guessing (cannot send chat)" do
      comp =
        base_component(%{
          new_message: "butterfly",
          is_drawer: true,
          current_drawer: %{id: "user-1", name: "Alice"}
        })

      result = GamePage.action(:send_message, %{}, comp)

      # Drawer is completely blocked from chat — input just clears
      assert result.state.new_message == ""
      assert result.state.chat_messages == []
      assert result.next_command == nil
    end

    test "an already-guessed player's text is sent the same way" do
      comp = base_component(%{new_message: "butterfly", correct_guessers: ["user-1"]})
      result = GamePage.action(:send_message, %{}, comp)

      assert_submits(result, "butterfly")
      assert result.state.chat_messages == []
    end

    test "the same command is sent whether or not a word is known locally" do
      for word <- [nil, ""] do
        comp = base_component(%{new_message: "butterfly", current_word: word})
        result = GamePage.action(:send_message, %{}, comp)

        assert_submits(result, "butterfly")
        assert result.state.chat_messages == []
      end
    end
  end

  # ── 3. No Client-Side Classification ──────────────────────────────────

  describe "send_message — no client-side classification" do
    test "near misses and unrelated words are sent as plain text" do
      for text <- ["butter", "elephant", "bu"] do
        result = GamePage.action(:send_message, %{}, base_component(%{new_message: text}))

        assert result.state.new_message == ""
        assert_submits(result, text)
      end
    end

    test "drawer messages are blocked entirely" do
      comp =
        base_component(%{
          new_message: "butter",
          is_drawer: true,
          current_drawer: %{id: "user-1", name: "Alice"}
        })

      result = GamePage.action(:send_message, %{}, comp)

      # Drawer is blocked — no message sent, input cleared
      assert result.state.new_message == ""
      assert result.state.chat_messages == []
      assert result.next_command == nil
    end

    test "already-guessed players and missing words change nothing client-side" do
      for overrides <- [%{correct_guessers: ["user-1"]}, %{current_word: nil}] do
        comp = base_component(Map.put(overrides, :new_message, "butter"))
        assert_submits(GamePage.action(:send_message, %{}, comp), "butter")
      end
    end
  end

  # ── 4. Rate Limiting ───────────────────────────────────────────────────

  describe "send_message — rate limiting" do
    test "messages are blocked when rate_limited is true" do
      comp = base_component(%{new_message: "hello", rate_limited: true})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.chat_messages == []
      # message not cleared — it was just blocked
      assert result.state.new_message == "hello"
    end

    test "tracks message timestamps" do
      comp = base_component(%{new_message: "msg1"})
      result = GamePage.action(:send_message, %{}, comp)

      assert length(result.state.message_timestamps) == 1
    end

    test "activates rate limit after 4th message in 5 seconds" do
      now = System.monotonic_time(:millisecond)
      recent = [now - 100, now - 200, now - 300]

      comp =
        base_component(%{
          new_message: "too fast",
          message_timestamps: recent
        })

      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.rate_limited == true
    end

    test "old timestamps are pruned (> 5 seconds)" do
      now = System.monotonic_time(:millisecond)
      old_timestamps = [now - 10_000, now - 8_000, now - 6_000]

      comp =
        base_component(%{
          new_message: "hello",
          message_timestamps: old_timestamps
        })

      result = GamePage.action(:send_message, %{}, comp)

      # Old timestamps should be pruned, message goes through via command
      assert result.state.rate_limited == false
      # Messages no longer added locally — they go to server
      assert result.state.chat_messages == []
      # Only the new timestamp should remain
      assert length(result.state.message_timestamps) == 1
    end

    test "clear_rate_limit resets the flag" do
      comp = base_component(%{rate_limited: true})
      result = GamePage.action(:clear_rate_limit, %{}, comp)

      assert result.state.rate_limited == false
    end

    test "a server-side :rate_limited result sets the flag and clears it after 3 s" do
      result = GamePage.action(:guess_result, %{outcome: :rate_limited}, base_component())

      assert result.state.rate_limited == true
      assert result.next_action.name == :clear_rate_limit
      assert result.next_action.delay == 3_000
    end

    test "other guess results change nothing" do
      comp = base_component()

      for params <- [
            %{outcome: :correct, points: 300},
            %{outcome: :chat},
            %{outcome: :drawer_cannot_chat},
            %{outcome: :empty}
          ] do
        result = GamePage.action(:guess_result, params, comp)
        assert result.state == comp.state
        assert result.next_action == nil
      end
    end
  end

  # ── 5. System Messages ─────────────────────────────────────────────────

  # A room in game g1 as View.delta/1 projects it, at `seq`.
  defp delta(seq, attrs) do
    %RoomServer{
      room_id: "test-room",
      status: :playing,
      creator_id: "user-1",
      max_players: 4,
      players: base_component().state.players,
      game_id: "g1",
      current_round: 1,
      total_rounds: 5,
      current_drawer_id: "user-2",
      phase: :choosing,
      choice_deadline: System.monotonic_time(:millisecond) + 15_000
    }
    |> struct!(attrs)
    |> View.delta()
    |> Map.put(:seq, seq)
  end

  defp system_line(id, text),
    do: %{id: id, player_name: "System", message: text, timestamp: 1, type: :system}

  defp appended(line), do: %{message: line, seq: line.id}

  # A room event is a :chat_appended for its system line, then the :room_delta.
  defp event(comp, line, delta) do
    chat = GamePage.action(:chat_appended, appended(line), comp)
    assert chat.next_action.name == :scroll_chat
    GamePage.action(:room_delta, delta, %{chat | next_action: nil})
  end

  describe "system messages — game events via :chat_appended and :room_delta" do
    test "game start shows the system line and starts the game" do
      comp = base_component(%{game_started: false, game_id: "", round: 0, phase: :idle})
      line = system_line(1, "Game started! Bob is choosing a word …")

      result = event(comp, line, delta(2, []))

      assert result.state.chat_messages == [line]
      assert result.state.game_started == true
      assert result.state.phase == :choosing
      assert result.state.last_seq == 2
    end

    test "a new round adds its line in front of the earlier ones" do
      old = system_line(4, "Time's up! The word was butterfly.")
      comp = base_component(%{game_id: "g1", round: 1, last_seq: 5, chat_messages: [old]})
      line = system_line(6, "Round 2 — Charlie is choosing a word …")

      result = event(comp, line, delta(7, current_round: 2, current_drawer_id: "user-3"))

      assert result.state.chat_messages == [line, old]
      assert result.state.round == 2
      assert result.state.current_drawer.username == "Charlie"
    end

    test "game end goes to the score page" do
      comp = base_component(%{game_id: "g1", last_seq: 10})
      line = system_line(11, "Game over! Final scores are in.")

      over =
        delta(12,
          status: :post_game,
          game_id: nil,
          last_game_id: "g1",
          current_round: 0,
          current_drawer_id: nil,
          phase: :idle
        )

      result = event(comp, line, over)

      assert result.next_page == {ScrawlyWeb.Pages.GameScorePage, [game_id: "g1"]}
    end

    test "round end shows time's up and the revealed word" do
      comp = base_component(%{game_id: "g1", time_left: 5, last_seq: 20})
      line = system_line(21, "Time's up! The word was: butterfly. Nobody guessed.")

      result = event(comp, line, delta(22, phase: :round_end, current_word: "butterfly"))

      assert [timeout_msg] = result.state.chat_messages
      assert timeout_msg.message =~ "butterfly"
      assert result.state.revealed_word == "butterfly"
      assert result.state.phase == :round_end
      assert result.state.current_word == nil
    end

    test "a line the page already holds is not added twice" do
      line = system_line(3, "TEST once")
      comp = base_component(%{chat_messages: [line], last_seq: 2})

      result = GamePage.action(:chat_appended, appended(line), comp)

      assert result.state.chat_messages == [line]
      assert result.state.last_seq == 3
      assert result.next_action == nil
    end

    test "only the newest 50 lines are kept" do
      lines = for i <- 50..1//-1, do: system_line(i, "msg #{i}")
      comp = base_component(%{chat_messages: lines, last_seq: 50})

      result = GamePage.action(:chat_appended, appended(system_line(51, "new")), comp)

      assert length(result.state.chat_messages) == 50
      assert hd(result.state.chat_messages).id == 51
      assert List.last(result.state.chat_messages).id == 2
    end
  end

  # ── 6. Correct Guess Handling ──────────────────────────────────────────

  describe "correct guess handling" do
    test "a guess only sends :submit_guess; guessers and scores come from the server" do
      # user-2 is the drawer, user-1 types the word
      comp =
        base_component(%{
          new_message: "butterfly",
          time_left: 60,
          correct_guessers: [],
          current_drawer: %{id: "user-2", name: "Bob"}
        })

      result = GamePage.action(:send_message, %{}, comp)

      assert_submits(result, "butterfly")
      assert result.state.correct_guessers == []
      alice = Enum.find(result.state.players, &(&1.id == "user-1"))
      assert alice.score == 0
    end

    test "an already-guessed player's word is sent like any text" do
      comp =
        base_component(%{
          new_message: "butterfly",
          time_left: 60,
          correct_guessers: ["user-1"],
          current_drawer: %{id: "user-2", name: "Bob"}
        })

      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.chat_messages == []
      assert_submits(result, "butterfly")
    end
  end

  # ── 7. Message History Management ──────────────────────────────────────

  describe "message history — server-managed" do
    test "send_message does not modify local chat_messages (server manages history)" do
      existing =
        for i <- 1..49 do
          %{
            id: i,
            player_name: "Bot",
            message: "msg #{i}",
            timestamp: System.system_time(:millisecond),
            type: :chat
          }
        end

      comp = base_component(%{new_message: "overflow", chat_messages: existing})
      result = GamePage.action(:send_message, %{}, comp)

      # Local chat_messages unchanged — message sent to server via command
      assert length(result.state.chat_messages) == 49
      assert_submits(result, "overflow")
    end

    test ":room_resynced replaces local chat_messages with the snapshot's" do
      comp =
        base_component(%{
          game_started: true,
          game_id: "g1",
          last_seq: 5,
          chat_messages: [system_line(2, "TEST stale")]
        })

      server_messages =
        for i <- 1..3 do
          %{
            id: i,
            player_name: "Bot",
            message: "server msg #{i}",
            timestamp: System.system_time(:millisecond),
            type: :chat
          }
        end

      params = %{
        room_id: comp.props.room_id,
        status: :playing,
        players: comp.state.players,
        seq: 6,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        current_word: nil,
        round_remaining_ms: 55_000,
        round_active: true,
        correct_guessers: [],
        chat_messages: Enum.reverse(server_messages),
        drawing_strokes: [],
        name: "Test",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        is_drawer: false,
        word_display: "_ _ _ _ _",
        word_length: 5,
        revealed_word: nil,
        phase: :drawing,
        word_choices: [],
        drawer_name: "Bob"
      }

      result = GamePage.action(:room_resynced, params, comp)

      # Chat messages come from the snapshot (newest first).
      assert length(result.state.chat_messages) == 3
      assert hd(result.state.chat_messages).message == "server msg 3"
      assert result.state.last_seq == 6
    end
  end

  # Enter key is now handled by <form $submit> in ChatBox — no action to test

  # ── 9. Update Message ──────────────────────────────────────────────────

  describe "update_message" do
    test "updates new_message state" do
      comp = base_component()
      result = GamePage.action(:update_message, %{event: %{value: "typing..."}}, comp)

      assert result.state.new_message == "typing..."
    end

    test "handles empty value" do
      comp = base_component(%{new_message: "existing"})
      result = GamePage.action(:update_message, %{event: %{value: ""}}, comp)

      assert result.state.new_message == ""
    end
  end
end
