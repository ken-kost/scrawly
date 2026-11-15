defmodule ScrawlyWeb.Pages.ForeignBroadcastsTest do
  @moduledoc """
  A page restored by Back/Forward runs no init on the server, so the tab's
  bindings are still those of the page shown before, and that page's
  Realtime actions reach the restored one (QA C1: 14 page/action pairs
  raised FunctionClauseError). Every page handles every other page's
  broadcast action with an explicit no-op clause, and its restore command
  deletes the stale subscriptions (`ScrawlyWeb.RoomSubscriptions`).
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Component
  alias Scrawly.Games.RoomServer.Broadcasts
  alias ScrawlyWeb.Components.DrawingToolbar
  alias ScrawlyWeb.Pages.{GamePage, GameScorePage, HomePage, PastGamesPage, ProfilePage}

  @moduletag :capture_log

  # Every action name the app broadcasts, read from the producers in lib/:
  # `Broadcasts.publish(.., :name` and `Hologram.Realtime.broadcast_action(..,
  # :name`. A new broadcast shows up here and fails the walk below until each
  # page has a clause for it.
  defp broadcast_actions do
    publish = ~r/publish\(\s*(?:state\s*,\s*)?:(\w+)/
    realtime = ~r/broadcast_action\((?:[^()]|\([^()]*\))*?,\s*:(\w+)/s

    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      source = File.read!(path)

      Regex.scan(publish, source, capture: :all_but_first) ++
        Regex.scan(realtime, source, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.map(&String.to_atom/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The layout's own channel (`:online`, cid "layout"): never a page's.
  @layout_actions [:online_count_updated]

  @lobby_actions [
    :lobby_chat_cleared,
    :lobby_chat_received,
    :lobby_room_changed,
    :lobby_room_removed
  ]
  @room_actions [
    :chat_appended,
    :drawing_cleared,
    :drawing_undone,
    :private_state,
    :room_delta,
    :stroke_completed
  ]

  # What each page subscribes to itself.
  @own %{
    HomePage => @lobby_actions,
    GamePage => @room_actions,
    GameScorePage => @room_actions,
    ProfilePage => [],
    PastGamesPage => []
  }

  # Payloads as the producers send them.
  @params %{
    lobby_room_changed: %{
      room: %{room_id: "r-x", name: "TEST", code: "ABCD", status: :lobby, players: []}
    },
    lobby_room_removed: %{room_id: "r-x"},
    lobby_chat_received: %{id: 7, username: "TESTx", message: "hi", is_guest: false},
    lobby_chat_cleared: %{},
    room_delta: %{seq: 9, status: :playing, players: [], watchers: [], game_id: "g"},
    chat_appended: %{seq: 9, message: %{id: 9, message: "hi", type: :system}},
    stroke_completed: %{seq: 9, stroke_id: "s-1", path: "M 1 1", color: "#000000", width: 2},
    drawing_cleared: %{seq: 9, op_epoch: "e"},
    drawing_undone: %{seq: 9, stroke_id: "s-1"},
    private_state: %{
      game_id: "g",
      round: 1,
      phase: :choosing,
      current_word: nil,
      word_choices: []
    }
  }

  test "the producers' action names are the ones this test knows" do
    assert broadcast_actions() == Enum.sort(@lobby_actions ++ @room_actions ++ @layout_actions)
  end

  test "every page takes every other page's broadcast action without raising or acting" do
    pairs =
      for {page, own} <- @own, action <- broadcast_actions() -- (own ++ @layout_actions) do
        {page, action}
      end

    # Home 6, Game 4, Score 4, Profile 10, History 10.
    assert length(pairs) == 34

    for {page, action} <- pairs do
      # Any state: a foreign action never looks at it.
      component = %Component{props: %{room_id: "r1", game_id: "g1"}, state: %{marker: page}}

      result = page.action(action, Map.fetch!(@params, action), component)

      assert result == component, "#{inspect(page)}.action(#{inspect(action)}) acted"
    end
  end

  test "the clauses are explicit: an unknown action still raises (no catch-all)" do
    for page <- Map.keys(@own) do
      assert_raise FunctionClauseError, fn ->
        page.action(:not_a_broadcast, %{}, %Component{state: %{}})
      end
    end
  end

  # ── Restores drop the stale subscriptions ─────────────────────────────

  defp page_server(user) do
    %{server_for(user) | cid: "page", instance_id: "i-#{System.unique_integer([:positive])}"}
  end

  defp ops(server), do: server.__meta__.subscription_ops

  defp deleted(server), do: for({key, :delete} <- ops(server), do: key) |> Enum.sort()
  defp put(server), do: for({key, :put} <- ops(server), do: key) |> Enum.sort()

  defp room_keys(room_id, uid) do
    [
      {Broadcasts.room_channel(room_id), "page"},
      {Broadcasts.player_channel(room_id, uid), "page"}
    ]
  end

  setup do
    user = create_user()
    stale = Ecto.UUID.generate()
    %{user: user, stale: stale, server: page_server(user)}
  end

  test "HomePage :resync_lobby keeps :lobby and drops the rooms the tab listed", ctx do
    params = %{stale_rooms: [ctx.stale, "not-a-uuid", 42]}
    result = HomePage.command(:resync_lobby, params, ctx.server)

    assert deleted(result) == Enum.sort(room_keys(ctx.stale, ctx.user.id))
    assert put(result) == [{:lobby, "page"}]
    assert result.next_action.name == :lobby_resynced

    # Without a list (or a forged one) only :lobby is put back.
    for params <- [%{}, %{stale_rooms: "x"}, "junk"] do
      result = HomePage.command(:resync_lobby, params, ctx.server)
      assert deleted(result) == []
      assert put(result) == [{:lobby, "page"}]
    end
  end

  test "GamePage :resync_room on a restore drops :lobby and other rooms, keeps its own", ctx do
    creator = create_user()
    room = start_room(creator)

    params = %{room_id: room.id, resubscribe: true, stale_rooms: [ctx.stale, room.id]}
    result = GamePage.command(:resync_room, params, page_server(creator))

    assert deleted(result) ==
             Enum.sort([{:lobby, "page"} | room_keys(ctx.stale, creator.id)])

    assert put(result) == Enum.sort(room_keys(room.id, creator.id))
    assert result.next_action.name == :room_resynced

    # A gap resync (no restore) touches no subscription.
    plain = GamePage.command(:resync_room, %{room_id: room.id}, page_server(creator))
    assert ops(plain) == %{}
  end

  test "ProfilePage and PastGamesPage drop :lobby and every listed room", ctx do
    for page <- [ProfilePage, PastGamesPage] do
      result =
        page.command(:drop_stale_subscriptions, %{stale_rooms: [ctx.stale]}, ctx.server)

      assert deleted(result) == Enum.sort([{:lobby, "page"} | room_keys(ctx.stale, ctx.user.id)])
      assert put(result) == []
    end
  end

  test "a restore never replays the navigation that left the page" do
    # Hologram 0.12.8 saves the component with the next_page that left it;
    # the restored page's first action would navigate there again.
    left = {GamePage, room_id: "r1"}

    pages = [
      {HomePage, %{page_shown?: true, draw_tool: DrawingToolbar.default_tool()}},
      {ProfilePage, %{page_shown?: true}},
      {PastGamesPage, %{page_shown?: true}},
      {GameScorePage, %{page_shown?: true, room_id: nil, room_dissolved: true, leaving: true}},
      {GamePage, %{room_missing?: true, page_shown?: true}}
    ]

    for {page, state} <- pages do
      component = %Component{
        props: %{room_id: "r1", game_id: "g1"},
        state: state,
        next_page: left
      }

      result = page.action(:page_shown, %{}, component)
      assert result.next_page == nil, inspect(page)
    end
  end

  test "the restore actions send the tab's room list with their command" do
    # Server-side JS.call returns :ok, which the pages send as [].
    home =
      HomePage.action(:page_shown, %{}, %Component{
        state: %{page_shown?: true, draw_tool: DrawingToolbar.default_tool()}
      })

    assert home.next_command.params == %{stale_rooms: []}

    for page <- [ProfilePage, PastGamesPage] do
      first = page.action(:page_shown, %{}, %Component{state: %{page_shown?: false}})
      assert first.state.page_shown? == true
      assert first.next_command == nil

      again = page.action(:page_shown, %{}, first)
      assert again.next_command.name == :drop_stale_subscriptions
      assert again.next_command.params == %{stale_rooms: []}
    end
  end
end
