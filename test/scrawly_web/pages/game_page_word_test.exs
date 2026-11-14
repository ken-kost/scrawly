defmodule ScrawlyWeb.Pages.GamePageWordTest do
  @moduledoc """
  The secret word and the word choices reach only the drawer. Page state
  (`init/3`), `:room_refreshed` replies and `:room_delta` broadcasts are all
  built from per-viewer views (`RoomServer.View`), whatever the params say.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.{RoomServer, WordHints}
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @word "zzyzx"
  @choices [@word, "TESTquokka", "TESTfjord"]
  @stroke %{path: "M0 0 L10 10", color: "#d63838", width: 5}

  setup do
    creator = create_user()
    guesser = create_user()
    spectator = create_user()
    room = start_room(creator)

    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(guesser)).next_action.name ==
             :room_refreshed

    {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: @choices})
    on_exit(fn -> Games.stop_round_timer(started.game_id) end)

    assert GamePage.command(:join_as_watcher, %{room_id: room.id}, server_for(spectator)).next_action.name ==
             :room_refreshed

    %{
      room: room,
      game_id: started.game_id,
      creator: creator,
      guesser: guesser,
      spectator: spectator
    }
  end

  defp choose!(%{room: room, creator: creator}) do
    {:ok, %{phase: :drawing}} = RoomServer.choose_word(room.id, creator.id, @word)
    :ok
  end

  # Stops the round timer and sets time_left as a tick would.
  defp tick!(%{room: room, game_id: game_id}, seconds) do
    Games.stop_round_timer(game_id)
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    send(pid, {:timer_update, %{remaining_seconds: seconds}})
    assert room_state!(room.id).time_left == seconds
  end

  defp init_page(room, server) do
    assert {component, _server} =
             GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server)

    component
  end

  defp non_drawers(ctx) do
    [
      guesser: server_for(ctx.guesser),
      spectator: server_for(ctx.spectator),
      anon: anon_server("anon-#{System.unique_integer([:positive])}"),
      empty: %Hologram.Server{}
    ]
  end

  defp dump(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp refute_leaks(term, words) do
    for word <- List.wrap(words) do
      refute dump(term) =~ word, "#{inspect(word)} leaked"
    end
  end

  defp assert_no_secret(view) do
    assert view.is_drawer == false
    assert view.current_word == nil
    assert view.word_choices == []
    refute_leaks(view, @choices)
  end

  defp assert_denied(result, command, reason) do
    assert result.next_action.name == :command_denied
    assert result.next_action.params.command == command
    assert result.next_action.params.reason == reason
    refute_leaks(result, @choices)
  end

  describe "init/3" do
    test "non-drawers get a masked display, no word and no choices; the drawer gets the word",
         ctx do
      choose!(ctx)

      for {who, server} <- non_drawers(ctx) do
        state = init_page(ctx.room, server).state

        assert state.current_word == nil, "#{who} got the word"
        assert state.word_choices == []
        assert state.is_drawer == false
        assert state.current_word_display =~ ~r/^[_ ]+$/
        assert state.word_length == 5
        assert state.revealed_word == nil
        refute_leaks(state, @choices)
      end

      drawer = init_page(ctx.room, server_for(ctx.creator)).state
      assert drawer.is_drawer == true
      assert drawer.current_word == @word
    end

    test "while choosing, only the drawer's page holds the choices", ctx do
      for {_who, server} <- non_drawers(ctx) do
        state = init_page(ctx.room, server).state
        assert state.word_choices == []
        assert state.phase == :choosing
        refute_leaks(state, @choices)
      end

      drawer = init_page(ctx.room, server_for(ctx.creator)).state
      assert drawer.word_choices == @choices
      assert drawer.choice_time_left in 1..15
    end

    test "a reload shows the current hint, and the drawer keeps the word", ctx do
      choose!(ctx)
      tick!(ctx, 30)

      hint = WordHints.generate_hint(@word, 30, 60)
      assert hint =~ ~r/[a-z]/

      for {_who, server} <- non_drawers(ctx) do
        state = init_page(ctx.room, server).state
        assert state.current_word_display == hint
        assert state.current_word == nil
      end

      assert init_page(ctx.room, server_for(ctx.creator)).state.current_word == @word
    end
  end

  describe "command replies" do
    test "a non-drawer's :poll_room_state carries no word or choices, even with forged ids",
         ctx do
      forged = %{
        room_id: ctx.room.id,
        user_id: ctx.creator.id,
        player_id: ctx.creator.id,
        viewer_id: ctx.creator.id
      }

      for phase <- [:choosing, :drawing] do
        if phase == :drawing, do: choose!(ctx)

        for {_who, server} <- non_drawers(ctx) do
          result = GamePage.command(:poll_room_state, forged, server)

          assert result.next_action.name == :room_refreshed
          assert result.next_action.params.phase == phase
          assert_no_secret(result.next_action.params)
        end
      end

      drawer =
        GamePage.command(:poll_room_state, %{room_id: ctx.room.id}, server_for(ctx.creator))

      assert drawer.next_action.params.current_word == @word
    end

    test ":choose_word acts only for the session drawer and leaks nothing to others", ctx do
      forged = %{room_id: ctx.room.id, word: @word, player_id: ctx.creator.id}

      guesser = GamePage.command(:choose_word, forged, server_for(ctx.guesser))
      assert_denied(guesser, :choose_word, :not_drawer)

      spectator = GamePage.command(:choose_word, forged, server_for(ctx.spectator))
      assert_denied(spectator, :choose_word, :not_drawer)

      anon = GamePage.command(:choose_word, forged, anon_server())
      assert_denied(anon, :choose_word, :unauthenticated)

      assert room_state!(ctx.room.id).phase == :choosing

      bad = %{room_id: ctx.room.id, word: "TESTnotachoice"}

      assert_denied(
        GamePage.command(:choose_word, bad, server_for(ctx.creator)),
        :choose_word,
        :invalid_word
      )

      result =
        GamePage.command(
          :choose_word,
          %{room_id: ctx.room.id, word: @word},
          server_for(ctx.creator)
        )

      assert result.next_action.name == :room_refreshed
      assert result.next_action.params.is_drawer == true
      assert result.next_action.params.current_word == @word
      assert result.next_action.params.phase == :drawing
      assert result.next_action.params.drawing_strokes == []
      assert room_state!(ctx.room.id).phase == :drawing
    end

    test "a non-creator's :start_game is denied without leaking the choices", ctx do
      forged = %{room_id: ctx.room.id, user_id: ctx.creator.id}

      for {_who, server} <- Keyword.take(non_drawers(ctx), [:guesser, :spectator]) do
        assert_denied(GamePage.command(:start_game, forged, server), :start_game, :not_creator)
      end
    end

    test ":start_game replies with the session user's own view" do
      creator = create_user()
      player = create_user()
      room = start_room(creator)
      GamePage.command(:join_room, %{room_id: room.id}, server_for(player))
      seed_test_words()

      result = GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      assert result.next_action.name == :room_refreshed

      assert %{is_drawer: true, phase: :choosing, word_choices: [_ | _] = choices} =
               result.next_action.params

      as_player = GamePage.command(:poll_room_state, %{room_id: room.id}, server_for(player))
      assert as_player.next_action.params.word_choices == []
      refute_leaks(as_player, choices)
    end

    test "a spectator joining mid-round gets no word, doesn't crash and keeps the strokes",
         ctx do
      choose!(ctx)
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, @stroke)

      for server <- [server_for(create_user()), anon_server("late-anon")] do
        component = init_page(ctx.room, server)
        assert component.state.watching? == true
        assert component.state.drawing_strokes == [@stroke]
        assert component.next_action.name == :do_join_as_watcher

        result = GamePage.command(:join_as_watcher, %{room_id: ctx.room.id}, server)
        assert result.next_action.name == :room_refreshed
        assert_no_secret(result.next_action.params)

        refreshed = GamePage.action(:room_refreshed, result.next_action.params, component)

        assert refreshed.state.drawing_strokes == [@stroke]
        assert refreshed.state.current_word == nil
        assert refreshed.state.current_word_display =~ ~r/^[_ ]+$/
        assert refreshed.state.word_length == 5
      end
    end
  end

  describe "hints and the reveal" do
    test "a tick's :room_delta brings the hint to a guesser's page without a poll", ctx do
      choose!(ctx)
      component = init_page(ctx.room, server_for(ctx.guesser))

      Phoenix.PubSub.subscribe(
        Hologram.PubSub,
        Hologram.Realtime.channel_topic({:room, ctx.room.id})
      )

      tick!(ctx, 30)

      assert_receive {:broadcast_action, _, :room_delta, %{time_left: 30} = delta, _}
      refute_leaks(delta, @word)

      updated = GamePage.action(:room_delta, delta, component)

      assert updated.state.current_word_display == WordHints.generate_hint(@word, 30, 60)
      assert updated.state.time_left == 30
      assert updated.next_command == nil
    end

    test "everyone sees the word once everyone has guessed", ctx do
      choose!(ctx)
      spectator_page = init_page(ctx.room, server_for(ctx.spectator))

      guess = %{room_id: ctx.room.id, text: @word}
      GamePage.command(:submit_guess, guess, server_for(ctx.guesser))
      assert room_state!(ctx.room.id).phase == :round_end

      for {_who, server} <- non_drawers(ctx) do
        params =
          GamePage.command(:poll_room_state, %{room_id: ctx.room.id}, server).next_action.params

        assert params.revealed_word == @word
        assert params.current_word == nil
        assert params.word_choices == []
      end

      reply =
        GamePage.command(:poll_room_state, %{room_id: ctx.room.id}, server_for(ctx.spectator))

      updated = GamePage.action(:room_refreshed, reply.next_action.params, spectator_page)
      assert updated.state.revealed_word == @word
      assert updated.state.phase == :round_end
    end
  end
end
