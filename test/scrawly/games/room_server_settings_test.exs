defmodule Scrawly.Games.RoomServerSettingsTest do
  @moduledoc """
  The host changes a room's settings in its lobby (lobby-settings):
  `RoomServer.update_settings/3` and the Room's `:update_settings` action.

    * Only the creator, only in `:lobby` (never during a game or the
      post-game pause); anything else changes nothing and sends nothing.
    * Values the Room refuses, and a player limit below the players already
      in the room, change nothing.
    * A change is stored (a restarted room has it), reaches every page as a
      sequenced `:room_delta` with one "the host changed the settings" line,
      and Home's room list as `:lobby_room_changed`.
    * The next game plays with it: answer kind, draw time, turns, theme and
      AI style; after a game, back in the lobby, it can change again.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.{AnswerKind, RoomServer}
  alias Scrawly.Games.RoomServer.View
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @line "the host changed the settings"

  @phrases_2min %{
    name: "TEST renamed",
    max_players: 6,
    answer_kind: :phrases,
    word_source: :local,
    round_duration: 120,
    round_multiplier: 2
  }

  setup do
    creator = create_user()
    player = create_user()
    room = start_room(creator, %{name: "TEST settings", max_players: 4, answer_kind: :words})
    # As the page joins: the room and the DB membership (kept after a game).
    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(player)).next_action.name ==
             :room_resynced

    %{room: room, creator: creator, player: player}
  end

  defp player_map(user), do: %{id: user.id, username: user.username, score: 0}

  defp subscribe(channel),
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))

  # Every broadcast received so far (waiting `ms` for stragglers), in order.
  defp drain(ms \\ 50, acc \\ []) do
    receive do
      {:broadcast_action, channel, action, params, _except} ->
        drain(ms, [{channel, action, params} | acc])
    after
      ms -> Enum.reverse(acc)
    end
  end

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp settings(room_id), do: room_id |> room_state!() |> View.settings()

  defp stored(room) do
    room |> reload_room!() |> Map.take(Map.keys(View.settings(%RoomServer{})))
  end

  defp end_game_and_return!(room) do
    {:ok, _} = RoomServer.end_game(room.id)
    send(pid_of(room), :return_to_lobby)
    assert %{status: :lobby, game_id: nil} = room_state!(room.id)
  end

  describe "the host, in the lobby" do
    test "changes the room, stores it and tells every page and Home", ctx do
      %{room: room, creator: creator} = ctx
      before = room_state!(room.id)
      subscribe({:room, room.id})
      subscribe(:lobby)

      assert {:ok, public} = RoomServer.update_settings(room.id, creator.id, @phrases_2min)
      assert Map.take(public, Map.keys(@phrases_2min)) == @phrases_2min

      state = room_state!(room.id)
      assert Map.take(state, Map.keys(@phrases_2min)) == @phrases_2min
      assert Map.take(stored(room), Map.keys(@phrases_2min)) == @phrases_2min
      assert state.players == before.players

      messages = drain()

      assert [
               {{:room, _}, :chat_appended, %{message: %{message: @line, type: :system}} = chat},
               {{:room, _}, :room_delta, delta},
               {:lobby, :lobby_room_changed, %{room: summary}}
             ] = messages

      # Sequenced like every {:room} broadcast: no gap, nothing skipped.
      assert chat.seq == before.seq + 1
      assert delta.seq == before.seq + 2
      assert Map.take(delta, Map.keys(@phrases_2min)) == @phrases_2min
      assert delta.status == :lobby and length(delta.players) == 2
      assert struct_free?(delta) and struct_free?(summary)

      assert %{
               name: "TEST renamed",
               max_players: 6,
               answer_kind: :phrases,
               round_duration: 120,
               round_multiplier: 2
             } = summary

      # Home's list, read at page load, has it too.
      assert Enum.find(RoomServer.list_lobby_rooms(), &(&1.room_id == room.id)) == summary
      assert Enum.count(state.chat_messages, &(&1.message == @line)) == 1
    end

    test "a second subscriber's page shows it from the delta alone", ctx do
      %{room: room, creator: creator, player: player} = ctx

      {page, _server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, server_for(player))

      page = %{page | props: %{room_id: room.id}}
      assert page.state.answer_kind == :words
      subscribe({:room, room.id})

      {:ok, _} = RoomServer.update_settings(room.id, creator.id, @phrases_2min)

      page =
        Enum.reduce(drain(), page, fn {{:room, _}, action, params}, page ->
          GamePage.action(action, params, page)
        end)

      assert page.state.answer_kind == :phrases
      assert page.state.round_duration == 120
      assert page.state.round_multiplier == 2
      assert page.state.max_players == 6
      assert page.state.room_name == "TEST renamed"
      assert Enum.any?(page.state.chat_messages, &(&1.message == @line))
    end

    test "a themed room: theme and style; back to everything drops the theme", ctx do
      %{room: room, creator: creator} = ctx

      themed = %{word_source: :ai, prompt: "TEST ocean", ai_tone: :weird}
      {:ok, _} = RoomServer.update_settings(room.id, creator.id, themed)
      assert %{word_source: :ai, prompt: "TEST ocean", ai_tone: :weird} = stored(room)

      summary = Enum.find(RoomServer.list_lobby_rooms(), &(&1.room_id == room.id))
      assert summary.prompt == "TEST ocean"

      {:ok, _} = RoomServer.update_settings(room.id, creator.id, %{word_source: :local})
      assert %{word_source: :local, prompt: nil} = settings(room.id)
      assert %{word_source: :local, prompt: nil} = stored(room)
    end

    test "the same settings again change nothing and send nothing", ctx do
      %{room: room, creator: creator} = ctx
      {:ok, _} = RoomServer.update_settings(room.id, creator.id, @phrases_2min)
      before = room_state!(room.id)
      subscribe({:room, room.id})
      subscribe(:lobby)

      assert {:ok, _} = RoomServer.update_settings(room.id, creator.id, @phrases_2min)

      assert drain() == []
      assert room_state!(room.id).seq == before.seq
      assert room_state!(room.id).chat_messages == before.chat_messages
    end

    test "a restarted room comes back with the new settings", ctx do
      %{room: room, creator: creator} = ctx
      {:ok, _} = RoomServer.update_settings(room.id, creator.id, @phrases_2min)

      kill_room!(room)
      {:ok, _pid} = RoomServer.ensure_started(room.id)

      assert Map.take(settings(room.id), Map.keys(@phrases_2min)) == @phrases_2min
    end

    test "the player limit can't go below the players in the room", ctx do
      %{room: room, creator: creator} = ctx
      {:ok, _} = RoomServer.join(room.id, player_map(create_user()))
      before = room_state!(room.id)
      subscribe({:room, room.id})

      assert RoomServer.update_settings(room.id, creator.id, %{max_players: 2}) ==
               {:error, {:max_players_below, 3}}

      assert room_state!(room.id) == before
      assert stored(room).max_players == 4
      assert drain() == []

      assert {:ok, %{max_players: 3}} =
               RoomServer.update_settings(room.id, creator.id, %{max_players: 3})
    end

    test "values the Room refuses change nothing", ctx do
      %{room: room, creator: creator} = ctx
      before = room_state!(room.id)
      stored_before = stored(room)
      subscribe({:room, room.id})
      subscribe(:lobby)

      for {attrs, field} <- [
            {%{name: String.duplicate("a", 41)}, :name},
            {%{name: String.duplicate("é", 30) <> String.duplicate("́", 200)}, :name},
            {%{name: nil}, :name},
            {%{word_source: :ai, prompt: nil}, :prompt},
            {%{word_source: :ai, prompt: "   "}, :prompt},
            {%{word_source: :ai, prompt: String.duplicate("a", 201)}, :prompt},
            {%{max_players: 13}, :max_players},
            {%{max_players: "abc"}, :max_players},
            {%{round_duration: 30}, :round_duration},
            {%{round_multiplier: 9}, :round_multiplier},
            {%{answer_kind: :sentences}, :answer_kind},
            {%{ai_tone: :rude}, :ai_tone}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 RoomServer.update_settings(room.id, creator.id, attrs),
               inspect(attrs)

        assert field in Enum.map(errors, &Map.get(&1, :field)), inspect({attrs, errors})
      end

      assert room_state!(room.id) == before
      assert stored(room) == stored_before
      assert drain() == []
    end

    test "only the settings fields: status, code and creator are not inputs", ctx do
      %{room: room} = ctx

      for attrs <- [%{status: :ended}, %{code: "AAAAAA"}, %{creator_id: Ecto.UUID.generate()}] do
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Invalid.NoSuchInput{}]}} =
                 Games.update_room_settings(room.id, attrs)
      end

      assert %{status: :lobby, creator_id: creator_id} = reload_room!(room)
      assert creator_id == ctx.creator.id
    end
  end

  describe "refused, nothing changes" do
    defp assert_refused(room, actor_id, reason) do
      before = room_state!(room.id)
      stored_before = stored(room)
      subscribe({:room, room.id})
      subscribe(:lobby)

      assert RoomServer.update_settings(room.id, actor_id, @phrases_2min) == {:error, reason}

      assert room_state!(room.id).seq == before.seq
      assert View.settings(room_state!(room.id)) == View.settings(before)
      assert stored(room) == stored_before
      assert drain() == []
    end

    test "a player who isn't the host, a watcher, a stranger, nobody", ctx do
      %{room: room, player: player} = ctx
      {:ok, _} = RoomServer.join_as_watcher(room.id, %{id: "anon:w", username: "TESTw"})

      for actor <- [player.id, "anon:w", create_user().id, nil] do
        assert_refused(room, actor, :not_creator)
      end
    end

    test "during a game", ctx do
      %{room: room, creator: creator} = ctx
      start_drawing!(room, creator)
      assert_refused(room, creator.id, :wrong_state)
    end

    test "while the drawer is choosing", ctx do
      %{room: room, creator: creator} = ctx
      {:ok, _} = RoomServer.start_game(room.id, creator.id, %{word_choices: choices(["zzyzx"])})
      assert_refused(room, creator.id, :wrong_state)
    end

    test "during the post-game pause", ctx do
      %{room: room, creator: creator} = ctx
      start_drawing!(room, creator)
      {:ok, %{status: :post_game}} = RoomServer.end_game(room.id)
      assert_refused(room, creator.id, :wrong_state)
    end

    test "a room with no process" do
      assert RoomServer.update_settings(Ecto.UUID.generate(), "u", %{}) == {:error, :not_found}
    end

    test "the Room itself takes settings only in its lobby", ctx do
      %{room: room} = ctx
      Games.start_game!(room.id)

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :status}]}} =
               Games.update_room_settings(room.id, %{name: "TEST late"})

      assert reload_room!(room).name == "TEST settings"
    end
  end

  describe "the next game" do
    setup do
      Games.sync_words()
      :ok
    end

    test "plays phrases, the new draw time and turns", ctx do
      %{room: room, creator: creator} = ctx
      {:ok, _} = RoomServer.update_settings(room.id, creator.id, @phrases_2min)

      start = GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))
      assert start.next_action == nil

      {:ok, view} = RoomServer.get_view(room.id, creator.id)
      assert view.phase == :choosing
      assert view.total_rounds == RoomServer.total_rounds(2, 2)
      assert length(view.word_choices) == 3

      for %{text: text} <- view.word_choices do
        assert AnswerKind.of(text) == :phrase, inspect(view.word_choices)
      end

      [%{text: text} | _] = view.word_choices
      {:ok, drawing} = RoomServer.choose_word(room.id, creator.id, text)
      assert drawing.round_duration == 120
      assert drawing.round_remaining_ms > 110_000 and drawing.round_remaining_ms <= 120_000
    end

    test "a themed room asks for the new theme and style", ctx do
      %{room: room, creator: creator} = ctx
      themed = %{word_source: :ai, prompt: "TEST ocean", ai_tone: :weird, answer_kind: :words}
      {:ok, _} = RoomServer.update_settings(room.id, creator.id, themed)

      GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))

      assert_received {:fake_ai_asked,
                       %{prompt: "TEST ocean", tone: "weird", answer_kind: :words}}

      assert %{status: :playing} = room_state!(room.id)
    end

    test "after a game, back in the lobby, the host changes them and starts again", ctx do
      %{room: room, creator: creator, player: player} = ctx
      start_drawing!(room, creator)
      end_game_and_return!(room)

      assert {:ok, _} = RoomServer.update_settings(room.id, creator.id, @phrases_2min)

      start = GamePage.command(:start_game, %{room_id: room.id}, server_for(creator))
      assert start.next_action == nil

      state = room_state!(room.id)
      assert state.status == :playing
      assert Enum.map(state.players, & &1.id) == [creator.id, player.id]

      {:ok, view} = RoomServer.get_view(room.id, creator.id)
      assert Enum.all?(view.word_choices, &(AnswerKind.of(&1.text) == :phrase))
    end
  end
end
