defmodule Scrawly.Games.CloseGuessTest do
  @moduledoc """
  Close guesses (play-feedback): a guess one edit away from the answer
  (`Guess.close?/2`: Damerau-Levenshtein distance 1 between `Guess.key/1`
  forms, answers of 5 or more characters) is never posted, broadcast or
  scored. Only its sender is told, with their own text, through the
  `:submit_guess` reply, the same path as the "contains the word" hint.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.{Guess, RoomServer}
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @drawer "drawer-id"
  @p1 "p1-id"
  @p2 "p2-id"
  @watcher "watcher-id"

  defp drawing_state(attrs) do
    struct!(
      %RoomServer{
        room_id: "TEST-room-#{System.unique_integer([:positive])}",
        status: :playing,
        creator_id: @drawer,
        max_players: 4,
        game_id: "TEST-game-#{System.unique_integer([:positive])}",
        phase: :drawing,
        current_round: 1,
        total_rounds: 3,
        current_drawer_id: @drawer,
        current_word: "popcorn",
        round_active: true,
        round_deadline: System.monotonic_time(:millisecond) + 60_000,
        round_duration: 60,
        players: [
          %{id: @drawer, username: "Drawer", score: 0},
          %{id: @p1, username: "P1", score: 0},
          %{id: @p2, username: "P2", score: 0}
        ],
        watchers: [%{id: @watcher, username: "Watcher"}],
        round_start_scores: %{@drawer => 0, @p1 => 0, @p2 => 0}
      },
      attrs
    )
  end

  defp submit(state, uid, text) do
    {:reply, reply, new_state} =
      RoomServer.handle_call({:submit_message, uid, text}, {self(), make_ref()}, state)

    {reply, new_state}
  end

  defp subscribe(channel),
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))

  describe "Guess.close?/2" do
    test "one edit of each kind is close" do
      for {guess, kind} <- [
            {"popcorm", :changed},
            {"popcrn", :missing},
            {"opcorn", :missing_first},
            {"popcor", :missing_last},
            {"popcornn", :added},
            {"xpopcorn", :added_first},
            {"popocrn", :swapped},
            {"oppcorn", :swapped_first},
            {"popconr", :swapped_last}
          ] do
        assert Guess.close?(guess, "popcorn"), "#{guess} (#{kind})"
      end
    end

    test "two edits, or the answer itself, are not close" do
      for guess <- ["popcorn", "POP-CORN!", "poocrm", "popcrom x", "pocorm", "corn", "popcornnn"] do
        refute Guess.close?(guess, "popcorn"), guess
      end
    end

    test "spacing, case, accents and punctuation never count as edits" do
      assert Guess.close?("Pop corm!!", "popcorn")
      assert Guess.close?("pop-corm", "popcorn")
      assert Guess.close?("chicken crossing the raod", "chicken crossing the road")
      assert Guess.close?("chickencrossingtheroad s", "chicken crossing the road")
      assert Guess.close?("crêpes", "crepe")
      assert Guess.close?("jack o lanterns", "jack-o'-lantern")
    end

    test "only answers whose key has at least 5 characters" do
      assert Guess.close_min_length() == 5
      refute Guess.close?("hut", "hat")
      refute Guess.close?("cats", "cat")
      refute Guess.close?("bost", "boat")
      # "t-shirt" has a 6-character key, "a b c d" only 4.
      assert Guess.close?("tshirts", "t-shirt")
      refute Guess.close?("abce", "a b c d")
      assert Guess.close?("hous", "house")
    end

    test "counts characters, not bytes" do
      # One changed letter of two or three bytes: two of its bytes differ.
      assert Guess.close?("привит", "привет")
      assert Guess.close?("ab日cd", "ab本cd")
      refute Guess.close?("ab日本d", "abxyd x")
    end

    test "never for empty or non-string input" do
      refute Guess.close?("", "popcorn")
      refute Guess.close?("!!!", "popcorn")
      refute Guess.close?(nil, "popcorn")
      refute Guess.close?("popcorm", nil)
      refute Guess.close?("popcorm", "")
      refute Guess.close?(<<0xFF, 0xFE>>, "popcorn")
    end
  end

  describe "in the room" do
    test "a close guess replies :close with the sender's own text and changes nothing" do
      state = drawing_state([])
      subscribe({:room, state.room_id})

      for text <- ["popcorm", "Pop Corm!", "popcrn"] do
        {reply, new_state} = submit(state, @p1, text)
        assert reply == {:ok, {:close, text}}

        # Not posted, not scored, not counted as a guess (only the chat rate).
        assert new_state.chat_messages == []
        assert new_state.correct_guessers == []
        assert new_state.players == state.players
        assert new_state.seq == state.seq

        assert Map.drop(Map.from_struct(new_state), [:chat_rate_limits]) ==
                 Map.drop(Map.from_struct(state), [:chat_rate_limits])
      end

      refute_received {:broadcast_action, _, _, _, _}
    end

    test "the echo is the sender's text only, cut to 40 characters" do
      state = drawing_state([])
      long = "p.o.p.c.o.r.m" <> String.duplicate("!", 60)
      assert {{:ok, {:close, echo}}, _} = submit(state, @p1, long)
      assert String.starts_with?(echo, "p.o.p.c.o.r.m")
      assert String.ends_with?(echo, "…")
      assert String.length(echo) == 41
      refute echo =~ "popcorn"
    end

    test "is private for anyone while drawing: a guesser who scored, a watcher" do
      state = drawing_state(correct_guessers: [@p2])
      assert {{:ok, {:close, "popcorm"}}, new_state} = submit(state, @p2, "popcorm")
      assert new_state.chat_messages == []

      assert {{:ok, {:close, "popcorm"}}, new_state} = submit(state, @watcher, "popcorm")
      assert new_state.chat_messages == []
    end

    test "is plain chat outside :drawing and for short answers" do
      for phase <- [:choosing, :round_end] do
        {reply, new_state} = submit(drawing_state(phase: phase), @p1, "popcorm")
        assert reply == {:ok, :chat}
        assert [%{message: "popcorm"}] = new_state.chat_messages
      end

      {reply, new_state} = submit(drawing_state(current_word: "boat"), @p1, "bost")
      assert reply == {:ok, :chat}
      assert [%{message: "bost"}] = new_state.chat_messages
    end

    test "a line containing the word is still suppressed, the word itself still scores" do
      state = drawing_state([])
      assert {{:ok, :suppressed}, _} = submit(state, @p1, "is it popcorn")
      assert {{:ok, {:correct, _points}}, _} = submit(state, @p1, "popcorn")
      # A longer line around a near miss is ordinary chat.
      assert {{:ok, :chat}, _} = submit(state, @p1, "is it popcorm")
    end

    test "counts against the chat rate limit like any line" do
      state = drawing_state([])
      {_, state} = submit(state, @p1, "popcorm")
      {_, state} = submit(state, @p1, "popcrn")
      {_, state} = submit(state, @p1, "popcorm")
      assert {{:error, :rate_limited}, _} = submit(state, @p1, "popcornn")
    end
  end

  describe "through the page command (live room)" do
    setup do
      drawer = create_user()
      sender = create_user()
      other = create_user()
      room = start_room(drawer)

      for user <- [sender, other] do
        assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
                 :room_resynced
      end

      start_drawing!(room, drawer, "popcorn")
      %{room: room, drawer: drawer, sender: sender, other: other}
    end

    test "only the sender hears of it, as their own text; nothing is pushed", ctx do
      %{room: room, sender: sender, other: other, drawer: drawer} = ctx
      before = room_state!(room.id)

      subscribe({:room, room.id})

      for user <- [sender, other, drawer], do: subscribe({:room_player, room.id, user.id})

      reply =
        GamePage.command(:submit_guess, %{room_id: room.id, text: "popcorm"}, server_for(sender))

      assert reply.next_action.name == :guess_result
      assert reply.next_action.params == %{outcome: :close, text: "popcorm"}

      refute_receive {:broadcast_action, _, _, _, _}, 100

      after_state = room_state!(room.id)
      assert after_state.seq == before.seq
      assert after_state.chat_messages == before.chat_messages
      assert after_state.correct_guessers == []
      assert Enum.map(after_state.players, & &1.score) == Enum.map(before.players, & &1.score)
      assert reload_user!(sender).score == 0
    end

    test "the sender's page shows \"'popcorm' is close!\" for 4 seconds", ctx do
      reply =
        GamePage.command(
          :submit_guess,
          %{room_id: ctx.room.id, text: "popcorm"},
          server_for(ctx.sender)
        )

      {page, _server} =
        GamePage.init(
          %{room_id: ctx.room.id},
          %Hologram.Component{props: %{room_id: ctx.room.id}},
          server_for(ctx.sender)
        )

      page = %{page | next_action: nil}
      result = GamePage.action(:guess_result, reply.next_action.params, page)

      assert result.state.chat_notice == "'popcorm' is close!"
      assert result.next_action.name == :clear_chat_notice
      assert result.next_action.delay == 4_000

      assert GamePage.action(:clear_chat_notice, result.next_action.params, result).state.chat_notice ==
               nil
    end
  end
end
