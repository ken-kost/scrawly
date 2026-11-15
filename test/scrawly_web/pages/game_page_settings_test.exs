defmodule ScrawlyWeb.Pages.GamePageSettingsTest do
  @moduledoc """
  The host changes the room's settings from the lobby (lobby-settings): an
  "edit" button on the settings panel opens the create-room form
  (`RoomSettingsForm`) filled with the room's settings, a fresh one on every
  opening; `:update_room_settings` parses the values as room creation does
  (`RoomSettings.to_attrs/2`) and answers with `:room_settings_saved`,
  `:room_settings_failed` (a field error in the form) or `:command_denied`.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Component
  alias Hologram.Component.Action
  alias Hologram.Template.Renderer
  alias Scrawly.Games.RoomServer
  alias Scrawly.Games.RoomServer.View
  alias ScrawlyWeb.Pages.GamePage
  alias ScrawlyWeb.RoomSettings

  @moduletag :capture_log

  # What the form sends: every value a string (RoomSettings.defaults/0 keys).
  @phrases_2min %{
    RoomSettings.defaults()
    | name: "TEST renamed",
      answer_kind: "phrases",
      round_duration: "120",
      round_multiplier: "2",
      max_players: "6"
  }

  setup do
    creator = create_user()
    player = create_user()
    room = start_room(creator, %{name: "TEST lobby", max_players: 4, answer_kind: :words})
    join!(room, player)
    %{room: room, creator: creator, player: player}
  end

  defp join!(room, user) do
    assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
             :room_resynced
  end

  defp page(room, user) do
    {component, _server} =
      GamePage.init(%{room_id: room.id}, %Component{props: %{room_id: room.id}}, server_for(user))

    %{component | next_action: nil}
  end

  defp render(component) do
    {html, _registry, _server} =
      GamePage.template().(Map.merge(component.props, component.state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  defp send_update(room, user_server, settings) do
    GamePage.command(:update_room_settings, %{room_id: room.id, settings: settings}, user_server)
  end

  defp reply(server), do: {server.next_action.name, server.next_action.params}

  defp subscribe(channel),
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))

  # The {:room} broadcasts received so far, in order.
  defp drain(acc \\ []) do
    receive do
      {:broadcast_action, {:room, _}, action, params, _except} -> drain([{action, params} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp open(component), do: GamePage.action(:edit_room_settings, %{}, component)

  defp hide(component), do: GamePage.action(:hide_room_settings, %{}, component)

  defp save(component, values \\ @phrases_2min),
    do: GamePage.action(:save_room_settings, %{values: values}, component)

  describe "the command" do
    test "the host's values change the room, parsed as room creation parses them", ctx do
      %{room: room, creator: creator} = ctx

      assert reply(send_update(room, server_for(creator), @phrases_2min)) ==
               {:room_settings_saved, %{}}

      assert %{
               name: "TEST renamed",
               answer_kind: :phrases,
               round_duration: 120,
               round_multiplier: 2,
               max_players: 6,
               word_source: :local
             } = room_state!(room.id)

      # A blank name is the host's default name, as when creating.
      send_update(room, server_for(creator), %{@phrases_2min | name: "  "})
      assert room_state!(room.id).name == creator.username <> "'s room"
    end

    test "only the settings: anything else in the values is ignored", ctx do
      %{room: room, creator: creator} = ctx
      forged = Map.merge(@phrases_2min, %{status: "ended", creator_id: ctx.player.id, code: "X"})

      assert reply(send_update(room, server_for(creator), forged)) == {:room_settings_saved, %{}}

      assert %{status: :lobby, code: code, creator_id: creator_id} = room_state!(room.id)
      assert code == room.code and creator_id == creator.id
      assert %{status: :lobby, creator_id: ^creator_id} = reload_room!(room)
    end

    test "anyone but the host is denied and nothing changes", ctx do
      %{room: room, player: player} = ctx
      before = View.settings(room_state!(room.id))

      for {server, reason} <- [
            {server_for(player), :not_creator},
            {server_for(create_user()), :not_creator},
            {anon_server(), :unauthenticated}
          ] do
        assert reply(send_update(room, server, @phrases_2min)) ==
                 {:command_denied, %{command: :update_room_settings, reason: reason}}
      end

      assert View.settings(room_state!(room.id)) == before
    end

    test "during a game it is denied and nothing changes", ctx do
      %{room: room, creator: creator} = ctx
      start_drawing!(room, creator)
      before = View.settings(room_state!(room.id))

      assert reply(send_update(room, server_for(creator), @phrases_2min)) ==
               {:command_denied, %{command: :update_room_settings, reason: :wrong_state}}

      assert View.settings(room_state!(room.id)) == before
    end

    test "values the room refuses get a field error and change nothing", ctx do
      %{room: room, creator: creator} = ctx
      {:ok, _} = RoomServer.join(room.id, %{id: create_user().id, username: "TESTc", score: 0})
      before = View.settings(room_state!(room.id))

      for {values, field, message} <- [
            {%{name: String.duplicate("a", 41)}, :name, "use a name of at most 40 characters"},
            {%{word_source: "ai", prompt: " "}, :prompt, "type a theme, or pick everything"},
            {%{word_source: "ai", prompt: String.duplicate("a", 201)}, :prompt,
             "use a theme of at most 200 characters"},
            {%{max_players: "13"}, :max_players, "pick 2 to 12 players"},
            {%{max_players: "abc"}, :max_players, "pick 2 to 12 players"},
            {%{max_players: "2"}, :max_players, "3 players are in the room, so pick 3 or more"},
            {%{round_duration: "30"}, nil, "couldn't save the settings, try again"}
          ] do
        assert reply(send_update(room, server_for(creator), Map.merge(@phrases_2min, values))) ==
                 {:room_settings_failed, %{field: field, message: message}},
               inspect(values)
      end

      assert View.settings(room_state!(room.id)) == before
    end

    test "malformed params are denied", ctx do
      %{room: room, creator: creator} = ctx

      for params <- [
            %{room_id: room.id},
            %{room_id: room.id, settings: "phrases"},
            %{room_id: room.id, settings: [answer_kind: "phrases"]},
            %{room_id: "nope", settings: @phrases_2min}
          ] do
        result = GamePage.command(:update_room_settings, params, server_for(creator))
        assert result.next_action.name == :command_denied
        assert result.next_action.params.reason == :invalid_params
      end
    end

    test "a room that is gone is denied", ctx do
      %{room: room, creator: creator} = ctx
      kill_room!(room)

      assert reply(send_update(room, server_for(creator), @phrases_2min)) ==
               {:command_denied, %{command: :update_room_settings, reason: :not_found}}
    end
  end

  describe "the edit button" do
    test "the host has one on the settings panel; other players don't", ctx do
      host_html = render(page(ctx.room, ctx.creator))

      assert host_html =~
               ~r{<div class="panel-head">\s*<span>settings</span>\s*<button type="button" class="app-btn app-btn-sm panel-head-btn">\s*edit\s*</button>}

      player_html = render(page(ctx.room, ctx.player))
      assert player_html =~ ~r{<div class="panel-head">\s*<span>settings</span>\s*</div>}
      refute player_html =~ "panel-head-btn"
    end

    test "is off while a start is on its way", ctx do
      starting = put_in(page(ctx.room, ctx.creator).state.starting_game?, true)

      assert render(starting) =~
               ~r{<button type="button" class="app-btn app-btn-sm panel-head-btn" disabled}

      assert open(starting) == starting
    end
  end

  describe "the form" do
    test "opens filled with the room's settings, a fresh form every time", ctx do
      {:ok, _} =
        RoomServer.update_settings(ctx.room.id, ctx.creator.id, %{
          word_source: :ai,
          prompt: "TEST ocean",
          ai_tone: :weird,
          round_duration: 300
        })

      lobby = page(ctx.room, ctx.creator)
      opened = open(lobby)

      assert opened.state.show_room_settings == true
      assert opened.state.room_settings_form == 1

      assert RoomSettings.form_values(opened.state.room_settings_initial) == %{
               name: "TEST lobby",
               answer_kind: "words",
               word_source: "ai",
               prompt: "TEST ocean",
               ai_tone: "weird",
               round_duration: "300",
               round_multiplier: "1",
               max_players: "4"
             }

      html = render(opened)
      assert html =~ ~s(<div class="scrim">)
      assert html =~ "room settings"
      assert html =~ ~s(id="room-settings-1-name")
      assert html =~ ~s(value="TEST lobby")
      assert html =~ ~s(value="TEST ocean")
      assert html =~ ~r{<button type="submit" class="app-btn app-btn-primary">\s*save\s*</button>}

      # Closed and opened again: a new cid, so the form starts again from
      # the room's settings instead of the last edits.
      again = opened |> hide() |> open()
      assert again.state.room_settings_form == 2
      refute render(hide(opened)) =~ "room-settings-1"
      assert render(again) =~ ~s(id="room-settings-2-name")
    end

    test "players: no limit below the players in the room, and it says why", ctx do
      {:ok, _} =
        RoomServer.join(ctx.room.id, %{id: create_user().id, username: "TESTc", score: 0})

      html = render(open(page(ctx.room, ctx.creator)))

      assert html =~ ~s(<option value="2" disabled="true">up to 2</option>)
      assert html =~ ~s(<option value="3">up to 3</option>)
      assert html =~ "3 players are in the room, so pick 3 or more"
    end

    test "other players and watchers can't open it", ctx do
      player_page = page(ctx.room, ctx.player)
      assert open(player_page) == player_page

      {watcher_page, _} =
        GamePage.init(
          %{room_id: ctx.room.id},
          %Component{props: %{room_id: ctx.room.id}},
          anon_server()
        )

      assert open(watcher_page) == watcher_page
    end

    test "save sends the values and waits; a second save sends nothing", ctx do
      saving = ctx.room |> page(ctx.creator) |> open() |> save()

      assert saving.state.saving_room_settings? == true
      assert saving.next_command.name == :update_room_settings
      assert saving.next_command.params == %{room_id: ctx.room.id, settings: @phrases_2min}

      assert saving.next_action == %Action{
               name: :save_room_settings_timed_out,
               params: %{attempt: 1},
               delay: 20_000
             }

      assert render(saving) =~ ~r{disabled="true">\s*saving…\s*</button>}
      assert save(%{saving | next_command: nil}).next_command == nil
    end

    test "saved: the form closes; the panel follows the room's broadcasts", ctx do
      %{room: room, creator: creator} = ctx
      saving = room |> page(creator) |> open() |> save()
      subscribe({:room, room.id})

      # The command, as the page would send it, then the reply.
      server = send_update(room, server_for(creator), saving.next_command.params.settings)
      saved = GamePage.action(server.next_action.name, server.next_action.params, saving)

      assert saved.state.show_room_settings == false
      assert saved.state.saving_room_settings? == false

      shown =
        Enum.reduce(drain(), saved, fn {action, params}, page ->
          GamePage.action(action, params, page)
        end)

      assert shown.state.last_seq == room_state!(room.id).seq

      assert Enum.any?(
               shown.state.chat_messages,
               &(&1.message == "the host changed the settings")
             )

      html = render(shown)
      assert html =~ ~s(<div class="k">answers</div><div class="v">phrases</div>)
      assert html =~ ~s(<div class="k">draw time</div><div class="v">2 min</div>)
      assert html =~ ~s(<div class="k">turns each</div><div class="v">2</div>)
      assert html =~ "players · 2/6"
      assert html =~ ~s(<h1 class="lobby-title">TEST renamed</h1>)
    end

    test "refused values: the error in the form, which stays open with its values", ctx do
      saving = ctx.room |> page(ctx.creator) |> open() |> save()

      failed =
        GamePage.action(
          :room_settings_failed,
          %{field: :max_players, message: "3 players are in the room, so pick 3 or more"},
          saving
        )

      assert failed.state.show_room_settings == true
      assert failed.state.saving_room_settings? == false

      assert failed.state.room_settings_errors == %{
               max_players: "3 players are in the room, so pick 3 or more"
             }

      assert render(failed) =~
               ~s(<div class="field-error">3 players are in the room, so pick 3 or more</div>)

      generic = GamePage.action(:room_settings_failed, %{field: nil, message: "x"}, saving)
      assert generic.state.room_settings_errors == %{form: "x"}
    end

    test "a denial: the reason in the form", ctx do
      saving = ctx.room |> page(ctx.creator) |> open() |> save()

      for {reason, text} <- [
            {:wrong_state, "settings can only change in the lobby"},
            {:not_creator, "only the host can change the settings"},
            {:not_found, "couldn't save the settings, try again"}
          ] do
        denied =
          GamePage.action(
            :command_denied,
            %{command: :update_room_settings, reason: reason},
            saving
          )

        assert denied.state.saving_room_settings? == false
        assert denied.state.room_settings_errors == %{form: text}
      end

      other = GamePage.action(:command_denied, %{command: :submit_guess, reason: :x}, saving)
      assert other.state.saving_room_settings? == true
    end

    test "no answer in time gives the form back; an older timeout does nothing", ctx do
      saving = ctx.room |> page(ctx.creator) |> open() |> save()

      timed_out = GamePage.action(:save_room_settings_timed_out, %{attempt: 1}, saving)
      assert timed_out.state.saving_room_settings? == false

      assert timed_out.state.room_settings_errors == %{
               form: "no answer from the server, try again"
             }

      again = save(timed_out)
      assert again.state.room_settings_attempt == 2
      assert GamePage.action(:save_room_settings_timed_out, %{attempt: 1}, again) == again
    end

    test "a reply after the host closed the form changes nothing", ctx do
      closed =
        ctx.room
        |> page(ctx.creator)
        |> open()
        |> save()
        |> hide()

      assert GamePage.action(:room_settings_saved, %{}, closed) == closed

      assert GamePage.action(:room_settings_failed, %{field: :name, message: "x"}, closed) ==
               closed
    end

    test "closes when the game starts, and after a Back/Forward restore", ctx do
      %{room: room, creator: creator} = ctx
      opened = room |> page(creator) |> open()

      {:ok, _} = RoomServer.start_game(room.id, creator.id, %{word_choices: choices(["zzyzx"])})
      {:ok, view} = RoomServer.get_view(room.id, creator.id)
      started = GamePage.action(:room_resynced, Map.put(view, :socket_token, "t"), opened)
      assert started.state.show_room_settings == false

      shown = put_in(opened.state.page_shown?, true)
      restored = GamePage.action(:page_shown, %{mount_id: shown.state.mount_id}, shown)
      assert restored.state.show_room_settings == false
    end
  end
end
