defmodule ScrawlyWeb.Pages.GamePageWordTest do
  @moduledoc """
  The secret word and the word choices reach only the drawer. Page state
  (`init/3`), `:room_resynced` snapshots and `:room_delta` broadcasts are all
  built from per-viewer views (`RoomServer.View`), whatever the params say;
  the drawer's own word and choices travel on their private `{:room_player}`
  channel and in their `choose_word` reply.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.{RoomServer, WordHints}
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @word "zzyzx"
  @choices [@word, "TESTquokka", "TESTfjord"]
  @stroke %{id: "s-word-1", path: "M0 0 L10 10", color: "#d63838", width: 5}

  setup do
    creator = create_user()
    guesser = create_user()
    spectator = create_user()
    room = start_room(creator)

    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(guesser)).next_action.name ==
             :room_resynced

    {:ok, started} =
      RoomServer.start_game(room.id, creator.id, %{word_choices: choices(@choices)})

    assert GamePage.command(:join_as_watcher, %{room_id: room.id}, server_for(spectator)).next_action.name ==
             :room_resynced

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

  # Reveals a hint stage of round 1 as the room's scheduled message does.
  defp reveal!(%{room: room, game_id: game_id}, stage) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    send(pid, {:hint_reveal, game_id, 1, stage})
    assert :sys.get_state(pid).hint_stage == stage
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
      assert drawer.word_choices == choices(@choices)
      assert drawer.choice_time_left in 1..15
      assert drawer.choice_remaining_ms in 1..15_000
      assert drawer.choice_duration == 15
    end

    test "a reload shows the current hint, and the drawer keeps the word", ctx do
      choose!(ctx)
      reveal!(ctx, 1)

      hint = WordHints.hint_for_stage(@word, 1)
      assert hint == WordHints.generate_hint(@word, 30, 60)
      assert hint =~ ~r/[a-z]/

      for {_who, server} <- non_drawers(ctx) do
        state = init_page(ctx.room, server).state
        assert state.current_word_display == hint
        assert state.current_word == nil
        assert state.time_left in 59..60
        assert state.round_remaining_ms in 58_000..60_000
      end

      assert init_page(ctx.room, server_for(ctx.creator)).state.current_word == @word
    end
  end

  describe "command replies" do
    test "a non-drawer's :resync_room carries no word or choices, even with forged ids",
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
          result = GamePage.command(:resync_room, forged, server)

          assert result.next_action.name == :room_resynced
          assert result.next_action.params.phase == phase
          assert_no_secret(result.next_action.params)
        end
      end

      drawer = GamePage.command(:resync_room, %{room_id: ctx.room.id}, server_for(ctx.creator))

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

      # The drawer's slice, without a seq.
      assert result.next_action.name == :private_state

      assert result.next_action.params == %{
               game_id: ctx.game_id,
               round: 1,
               phase: :drawing,
               current_word: @word,
               word_choices: []
             }

      assert room_state!(ctx.room.id).phase == :drawing
    end

    test "a non-creator's :start_game is denied without leaking the choices", ctx do
      forged = %{room_id: ctx.room.id, user_id: ctx.creator.id}

      for {_who, server} <- Keyword.take(non_drawers(ctx), [:guesser, :spectator]) do
        assert_denied(GamePage.command(:start_game, forged, server), :start_game, :not_creator)
      end
    end

    test ":start_game replies nothing; only the drawer's channel gets the choices" do
      creator = create_user()
      player = create_user()
      room = start_room(creator)
      GamePage.command(:join_room, %{room_id: room.id}, server_for(player))
      seed_test_words()

      for channel <- [{:room, room.id}, {:room_player, room.id, creator.id}] do
        Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))
      end

      player_id = player.id
      player_channel = {:room_player, room.id, player_id}
      Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(player_channel))

      result = GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))
      assert result.next_action == nil

      assert_receive {:broadcast_action, {:room_player, _, _}, :private_state,
                      %{phase: :choosing, word_choices: [_ | _] = choices} = slice, _}

      # One easy, one medium and one hard, for the drawer's eyes only.
      assert Enum.map(choices, & &1.difficulty) == [:easy, :medium, :hard]
      texts = Enum.map(choices, & &1.text)

      refute Map.has_key?(slice, :seq)
      assert_receive {:broadcast_action, {:room, _}, :room_delta, delta, _}
      refute_leaks(delta, texts)
      refute dump(delta) =~ ~r/:easy|:medium|:hard/
      refute_received {:broadcast_action, {:room_player, _, ^player_id}, _, _, _}

      as_player = GamePage.command(:resync_room, %{room_id: room.id}, server_for(player))
      assert as_player.next_action.params.word_choices == []
      assert as_player.next_action.params.word_difficulty == nil
      refute_leaks(as_player, texts)
      refute dump(as_player.next_action) =~ ~r/:easy|:medium|:hard/
    end

    test "a spectator joining mid-round gets no word, doesn't crash and keeps the strokes",
         ctx do
      choose!(ctx)
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, @stroke)

      for server <- [server_for(create_user()), anon_server("late-anon")] do
        component = init_page(ctx.room, server)
        assert component.state.watching? == true
        assert component.state.drawing_strokes == [@stroke]
        assert component.next_action.name == :mounted
        assert component.next_action.params.join == :watcher

        result = GamePage.command(:join_as_watcher, %{room_id: ctx.room.id}, server)
        assert result.next_action.name == :room_resynced
        assert_no_secret(result.next_action.params)

        refreshed = GamePage.action(:room_resynced, result.next_action.params, component)

        assert refreshed.state.drawing_strokes == [@stroke]
        assert refreshed.state.current_word == nil
        assert refreshed.state.current_word_display =~ ~r/^[_ ]+$/
        assert refreshed.state.word_length == 5
      end
    end
  end

  describe "hints and the reveal" do
    test "a reveal's :room_delta brings the hint to a guesser's page", ctx do
      choose!(ctx)
      component = init_page(ctx.room, server_for(ctx.guesser))

      Phoenix.PubSub.subscribe(
        Hologram.PubSub,
        Hologram.Realtime.channel_topic({:room, ctx.room.id})
      )

      reveal!(ctx, 1)

      assert_receive {:broadcast_action, _, :room_delta, %{phase: :drawing} = delta, _}
      refute_leaks(delta, @word)
      assert delta.round_remaining_ms in 58_000..60_000

      updated = GamePage.action(:room_delta, delta, component)

      assert updated.state.current_word_display == WordHints.hint_for_stage(@word, 1)
      assert updated.state.time_left in 59..60
      assert is_integer(updated.state.round_deadline_local)
      assert updated.next_command == nil
      # The page counts down by itself from here.
      assert updated.next_action.name == :countdown_tick
    end

    test "everyone sees the word once everyone has guessed", ctx do
      choose!(ctx)
      spectator_page = init_page(ctx.room, server_for(ctx.spectator))

      guess = %{room_id: ctx.room.id, text: @word}
      GamePage.command(:submit_guess, guess, server_for(ctx.guesser))
      assert room_state!(ctx.room.id).phase == :round_end

      for {who, server} <- non_drawers(ctx) do
        params =
          GamePage.command(:resync_room, %{room_id: ctx.room.id}, server).next_action.params

        assert params.revealed_word == @word
        # The guesser has had the word since their guess (play-feedback).
        assert params.current_word == if(who == :guesser, do: @word)
        assert params.word_choices == []
      end

      reply = GamePage.command(:resync_room, %{room_id: ctx.room.id}, server_for(ctx.spectator))

      updated = GamePage.action(:room_resynced, reply.next_action.params, spectator_page)
      assert updated.state.revealed_word == @word
      assert updated.state.phase == :round_end
    end
  end
end
