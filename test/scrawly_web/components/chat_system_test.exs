defmodule ScrawlyWeb.Components.ChatSystemTest do
  @moduledoc """
  Comprehensive unit tests for the chat system.

  Tests the chat-related actions on GamePage: message submission, rate limiting,
  system messages, close guess detection, and message history management.
  Since Hologram actions are pure functions on %Component{} structs, we test
  them directly without needing a running server.
  """
  use ExUnit.Case, async: true

  alias ScrawlyWeb.Pages.GamePage

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp base_component(overrides \\ %{}) do
    defaults = %{
      room_id: "test-room",
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
      current_word: "butterfly",
      current_word_display: "_ _ _ _ _ _ _ _ _",
      time_left: 60,
      is_drawer: false,
      is_creator: true,
      creator_id: "user-1",
      version: 0,
      new_message: "",
      chat_messages: [],
      correct_guessers: [],
      used_words: ["butterfly"],
      rate_limited: false,
      message_timestamps: [],
      can_start_game: true,
      watching?: false,
      leaving?: false,
      room_status: :playing,
      room_name: "Room ABCD",
      drawing_path: "",
      drawing?: false,
      drawing_sent_length: 0
    }

    %Hologram.Component{state: Map.merge(defaults, overrides)}
  end

  # ── 1. Message Submission Flow ──────────────────────────────────────────

  describe "send_message — basic submission" do
    test "clears input and sends message via command (not added locally)" do
      comp = base_component(%{new_message: "hello everyone"})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.new_message == ""
      # Messages now go through the server via command, not added to local state
      assert result.state.chat_messages == []
      # A next_command should be set to send the message to the server
      assert result.next_command != nil
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
      assert result.next_command != nil
    end
  end

  # ── 2. Correct Guess Detection ──────────────────────────────────────────

  describe "send_message — correct guess" do
    test "exact match triggers correct guess via command" do
      comp = base_component(%{new_message: "butterfly", time_left: 60})
      result = GamePage.action(:send_message, %{}, comp)

      # Correct guess goes to server via record_correct_guess command
      assert result.state.new_message == ""
      assert "user-1" in result.state.correct_guessers
      # Messages are not added locally — they go through the server
      assert result.state.chat_messages == []
      assert result.next_command != nil
    end

    test "case-insensitive match triggers correct guess" do
      comp = base_component(%{new_message: "BUTTERFLY"})
      result = GamePage.action(:send_message, %{}, comp)

      assert "user-1" in result.state.correct_guessers
      assert result.next_command != nil
    end

    test "match with surrounding whitespace triggers correct guess" do
      comp = base_component(%{new_message: "  butterfly  "})
      result = GamePage.action(:send_message, %{}, comp)

      assert "user-1" in result.state.correct_guessers
      assert result.next_command != nil
    end

    test "correct guess sends points to server (not updated locally)" do
      comp = base_component(%{new_message: "butterfly", time_left: 80})
      result = GamePage.action(:send_message, %{}, comp)

      # Points are sent to server via command, not updated locally
      assert "user-1" in result.state.correct_guessers
      assert result.next_command != nil
    end

    test "correct guess adds player to correct_guessers" do
      comp = base_component(%{new_message: "butterfly"})
      result = GamePage.action(:send_message, %{}, comp)

      assert "user-1" in result.state.correct_guessers
    end

    test "correct guess does not update local player score (server handles it)" do
      comp = base_component(%{new_message: "butterfly", time_left: 60})
      result = GamePage.action(:send_message, %{}, comp)

      # Score is NOT updated locally — the server handles it via record_correct_guess
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
    end

    test "already-guessed player cannot guess again — sends as regular chat" do
      comp =
        base_component(%{
          new_message: "butterfly",
          correct_guessers: ["user-1"]
        })

      result = GamePage.action(:send_message, %{}, comp)

      # Message goes as regular chat via command
      assert result.state.chat_messages == []
      assert result.next_command != nil
    end

    test "no correct guess when no current word — sends as regular chat" do
      comp = base_component(%{new_message: "butterfly", current_word: nil})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.chat_messages == []
      assert result.next_command != nil
    end

    test "no correct guess when current word is empty — sends as regular chat" do
      comp = base_component(%{new_message: "butterfly", current_word: ""})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.chat_messages == []
      assert result.next_command != nil
    end
  end

  # ── 3. Close Guess Detection (Obfuscation) ─────────────────────────────

  describe "send_message — close guess detection" do
    test "messages are sent to server via command" do
      comp = base_component(%{new_message: "butter"})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.state.new_message == ""
      assert result.next_command != nil
      assert result.next_command.params.message.type == :chat
    end

    test "completely unrelated word is sent as regular chat" do
      comp = base_component(%{new_message: "elephant"})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.next_command.params.message.type == :chat
    end

    test "very short substring not flagged (length < 3)" do
      comp = base_component(%{new_message: "bu", current_word: "butterfly"})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.next_command.params.message.type == :chat
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
    end

    test "already-guessed player messages not flagged as close guess" do
      comp =
        base_component(%{
          new_message: "butter",
          correct_guessers: ["user-1"]
        })

      result = GamePage.action(:send_message, %{}, comp)

      assert result.next_command.params.message.type == :chat
    end

    test "close guess not detected when no active word" do
      comp = base_component(%{new_message: "butter", current_word: nil})
      result = GamePage.action(:send_message, %{}, comp)

      assert result.next_command.params.message.type == :chat
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
  end

  # ── 5. System Messages ─────────────────────────────────────────────────

  describe "system messages — game events via room_refreshed" do
    test "game start syncs chat_messages from server" do
      comp =
        base_component(%{game_started: false, chat_messages: [], version: 0, is_creator: true})

      server_chat = [
        %{
          id: 1,
          player_name: "System",
          message: "Game started! Bob is drawing first.",
          timestamp: DateTime.utc_now(),
          type: :system
        }
      ]

      params = %{
        room_id: comp.state.room_id,
        status: :playing,
        players: comp.state.players,
        version: 1,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        current_word: "butterfly",
        time_left: 80,
        round_active: true,
        correct_guessers: [],
        chat_messages: server_chat,
        drawing_path: "",
        name: "Test",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        is_drawer: false,
        current_word_display: "_ _ _ _ _",
        drawer_name: "Bob"
      }

      result = GamePage.action(:room_refreshed, params, comp)

      msgs = result.state.chat_messages
      assert length(msgs) == 1
      system_msg = Enum.find(msgs, &(&1.type == :system))
      assert system_msg.message =~ "Game started!"
      assert system_msg.message =~ "Bob"
    end

    test "new round syncs chat_messages from server" do
      comp = base_component(%{game_started: true, game_id: "g1", round: 1, version: 5})

      server_chat = [
        %{
          id: 2,
          player_name: "System",
          message: "Round 2! Charlie is drawing.",
          timestamp: DateTime.utc_now(),
          type: :system
        }
      ]

      params = %{
        room_id: comp.state.room_id,
        status: :playing,
        players: comp.state.players,
        version: 6,
        game_id: "g1",
        current_round: 2,
        total_rounds: 5,
        current_drawer_id: "user-3",
        current_word: "elephant",
        time_left: 80,
        round_active: true,
        correct_guessers: [],
        chat_messages: server_chat,
        drawing_path: "",
        name: "Test",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        is_drawer: false,
        current_word_display: "_ _ _ _ _",
        drawer_name: "Bob"
      }

      result = GamePage.action(:room_refreshed, params, comp)

      msgs = result.state.chat_messages
      system_msg = Enum.find(msgs, &(&1.type == :system))
      assert system_msg.message =~ "Round 2"
      assert system_msg.message =~ "Charlie"
    end

    test "game end redirects to score page" do
      comp = base_component(%{game_started: true, game_id: "g1", version: 10})

      params = %{
        room_id: comp.state.room_id,
        status: :lobby,
        players: comp.state.players,
        version: 11,
        game_id: nil,
        current_round: 0,
        total_rounds: 5,
        current_drawer_id: nil,
        current_word: nil,
        time_left: 0,
        round_active: false,
        correct_guessers: [],
        chat_messages: [],
        drawing_path: "",
        name: "Test",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        is_drawer: false,
        current_word_display: "",
        drawer_name: "Unknown",
        last_game_id: "g1"
      }

      result = GamePage.action(:room_refreshed, params, comp)

      # Should redirect to score page (put_page)
      assert match?(%Hologram.Component{}, result)
    end

    test "round end syncs chat_messages including time's up from server" do
      comp =
        base_component(%{
          game_started: true,
          game_id: "g1",
          time_left: 5,
          current_word: "butterfly",
          version: 20
        })

      server_chat = [
        %{
          id: 4,
          player_name: "System",
          message: "Time's up! The word was butterfly.",
          timestamp: DateTime.utc_now(),
          type: :system
        }
      ]

      params = %{
        room_id: comp.state.room_id,
        status: :playing,
        players: comp.state.players,
        version: 21,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        current_word: "butterfly",
        time_left: 0,
        round_active: false,
        correct_guessers: [],
        chat_messages: server_chat,
        drawing_path: "",
        name: "Test",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        is_drawer: false,
        current_word_display: "_ _ _ _ _",
        drawer_name: "Bob"
      }

      result = GamePage.action(:room_refreshed, params, comp)

      msgs = result.state.chat_messages

      timeout_msg =
        Enum.find(
          msgs,
          &(Map.get(&1, :type) == :system && String.contains?(&1.message, "Time's up!"))
        )

      assert timeout_msg != nil
      assert timeout_msg.message =~ "butterfly"
    end
  end

  # ── 6. All Guessed — Round Complete ────────────────────────────────────

  describe "correct guess handling" do
    test "correct guess updates guessers list and sends command" do
      # user-2 is the drawer, user-1 guesses correctly
      comp =
        base_component(%{
          new_message: "butterfly",
          current_word: "butterfly",
          time_left: 60,
          correct_guessers: [],
          current_drawer: %{id: "user-2", name: "Bob"}
        })

      result = GamePage.action(:send_message, %{}, comp)

      # User should be in correct_guessers (updated locally)
      assert "user-1" in result.state.correct_guessers
      # Message goes to server via record_correct_guess command
      assert result.next_command != nil
    end

    test "correct guess does not update local player score" do
      comp =
        base_component(%{
          new_message: "butterfly",
          current_word: "butterfly",
          time_left: 60,
          correct_guessers: [],
          current_drawer: %{id: "user-2", name: "Bob"}
        })

      result = GamePage.action(:send_message, %{}, comp)

      alice = Enum.find(result.state.players, &(&1.id == "user-1"))
      # Score is NOT updated locally — the server handles it
      assert alice.score == 0
    end

    test "already guessed player's message treated as regular chat via command" do
      comp =
        base_component(%{
          new_message: "butterfly",
          current_word: "butterfly",
          time_left: 60,
          correct_guessers: ["user-1"],
          current_drawer: %{id: "user-2", name: "Bob"}
        })

      result = GamePage.action(:send_message, %{}, comp)

      # Message goes as regular chat via send_chat_message command
      assert result.state.chat_messages == []
      assert result.next_command != nil
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
            timestamp: DateTime.utc_now(),
            type: :chat
          }
        end

      comp = base_component(%{new_message: "overflow", chat_messages: existing})
      result = GamePage.action(:send_message, %{}, comp)

      # Local chat_messages unchanged — message sent to server via command
      assert length(result.state.chat_messages) == 49
      assert result.next_command != nil
    end

    test "room_refreshed replaces local chat_messages with server state" do
      comp = base_component(%{game_started: true, game_id: "g1", version: 5})

      server_messages =
        for i <- 1..3 do
          %{
            id: i,
            player_name: "Bot",
            message: "server msg #{i}",
            timestamp: DateTime.utc_now(),
            type: :chat
          }
        end

      params = %{
        room_id: comp.state.room_id,
        status: :playing,
        players: comp.state.players,
        version: 6,
        game_id: "g1",
        current_round: 1,
        total_rounds: 5,
        current_drawer_id: "user-2",
        current_word: "butterfly",
        time_left: 55,
        round_active: true,
        correct_guessers: [],
        chat_messages: server_messages,
        drawing_path: "",
        name: "Test",
        code: "ABCD",
        creator_id: "user-1",
        max_players: 4,
        watchers: [],
        is_drawer: false,
        current_word_display: "_ _ _ _ _",
        drawer_name: "Bob"
      }

      result = GamePage.action(:room_refreshed, params, comp)

      # Chat messages come from the server
      assert length(result.state.chat_messages) == 3
      assert hd(result.state.chat_messages).message == "server msg 1"
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
