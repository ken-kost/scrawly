defmodule ScrawlyWeb.Layouts.AppLayoutPresenceTest do
  @moduledoc """
  The header's "N online" as AppLayout keeps it: the count comes over
  Realtime (`:online`), and each tab keeps itself counted with a
  `:presence_ping` every 20 s from a gen-guarded chain, re-armed by a count
  update when it died (Back/Forward restore).
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers

  alias Hologram.{Component, Server}
  alias ScrawlyWeb.Auth
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Middleware.LoadCurrentUser
  alias ScrawlyWeb.OnlineTracker

  @moduletag :capture_log

  defp seen?(key) do
    # touch/1 is a cast; a count call first makes sure it has been handled.
    OnlineTracker.count()
    Map.has_key?(:sys.get_state(OnlineTracker).seen, key)
  end

  defp layout(state), do: %Component{state: state}
  defp now, do: System.monotonic_time(:millisecond)

  # What Hologram runs for a layout command: the layout's own middleware.
  defp layout_command(name, server) do
    server = Server.Middleware.run(server, AppLayout.__middleware__())
    AppLayout.command(name, %{}, server)
  end

  describe "init/3" do
    test "subscribes to :online, counts the visitor and starts the ping chain" do
      user = create_user()

      {component, server} =
        AppLayout.init(%{}, %Component{}, LoadCurrentUser.call(session_server(user), []))

      assert Enum.any?(server.subscriptions, &(elem(&1, 0) == :online))
      assert seen?(user.id)
      assert component.state.online_count >= 1
      assert component.state.last_ping_at == nil

      gen = component.state.ping_gen
      assert is_integer(gen)

      assert %{name: :presence_ping, params: %{gen: ^gen}, delay: 20_000} =
               component.next_action

      refute Map.has_key?(component.state, :tick_online)
    end

    test "every render seeds a new gen" do
      server = LoadCurrentUser.call(anon_server("TEST-#{System.unique_integer()}"), [])
      {a, _} = AppLayout.init(%{}, %Component{}, server)
      {b, _} = AppLayout.init(%{}, %Component{}, server)
      assert a.state.ping_gen != b.state.ping_gen
    end
  end

  describe ":presence_ping (the chain)" do
    test "the current gen pings and schedules the next ping of the same chain" do
      result =
        AppLayout.action(:presence_ping, %{gen: 7}, layout(%{ping_gen: 7, last_ping_at: nil}))

      assert %{name: :presence_ping} = result.next_command
      assert %{name: :presence_ping, params: %{gen: 7}, delay: 20_000} = result.next_action
      assert is_integer(result.state.last_ping_at)
      assert result.state.ping_gen == 7
    end

    test "a stale chain stops" do
      component = layout(%{ping_gen: 8, last_ping_at: nil})
      assert AppLayout.action(:presence_ping, %{gen: 7}, component) == component
    end
  end

  describe ":layout_shown (Back/Forward restore)" do
    test "the first one only marks the layout; a later one pings with resync and restarts the chain" do
      component = layout(%{ping_gen: 5, last_ping_at: nil, layout_shown?: false})

      first = AppLayout.action(:layout_shown, %{mount_id: "1"}, component)
      assert first.state.layout_shown? == true
      assert first.next_command == nil
      assert first.next_action == nil

      restored = AppLayout.action(:layout_shown, %{mount_id: "1"}, first)
      assert %{name: :presence_ping, params: %{resync: true}} = restored.next_command
      assert %{name: :presence_ping, params: %{gen: 6}, delay: 20_000} = restored.next_action
      assert restored.state.ping_gen == 6
      assert is_integer(restored.state.last_ping_at)
    end

    test "the template dispatches it from an inline script keyed by the instance's mount_id" do
      user = create_user()

      {component, _server} =
        AppLayout.init(%{}, %Component{}, LoadCurrentUser.call(session_server(user), []))

      assert component.state.layout_shown? == false
      assert is_integer(component.state.mount_id)

      source = File.read!("lib/scrawly_web/layouts/app_layout.ex")

      assert source =~
               ~s|<script>Hologram.dispatchAction("layout_shown", "layout", \\{mount_id: "{@mount_id}"\\});</script>|
    end
  end

  describe ":online_count_updated" do
    test "sets the count; a live chain is left alone" do
      component = layout(%{online_count: 1, ping_gen: 3, last_ping_at: now() - 5_000})
      result = AppLayout.action(:online_count_updated, %{count: 4}, component)

      assert result.state.online_count == 4
      assert result.next_command == nil
      assert result.next_action == nil
      assert result.state.ping_gen == 3
    end

    test "before the first ping it only records a baseline" do
      component = layout(%{online_count: 1, ping_gen: 3, last_ping_at: nil})
      result = AppLayout.action(:online_count_updated, %{count: 2}, component)

      assert is_integer(result.state.last_ping_at)
      assert result.next_command == nil
      assert result.next_action == nil
    end

    test "a chain silent for over 30 s (or stamped in the future) is restarted with gen + 1" do
      for last <- [now() - 31_000, now() + 60_000] do
        component = layout(%{online_count: 1, ping_gen: 3, last_ping_at: last})
        result = AppLayout.action(:online_count_updated, %{count: 2}, component)

        assert result.state.online_count == 2
        assert result.state.ping_gen == 4
        assert %{name: :presence_ping} = result.next_command
        assert %{name: :presence_ping, params: %{gen: 4}, delay: 20_000} = result.next_action

        # The old chain, if it was only late, now stops.
        assert AppLayout.action(:presence_ping, %{gen: 3}, result) == result
      end
    end
  end

  describe "command :presence_ping" do
    test "the layout runs LoadCurrentUser (id only) before its commands" do
      assert AppLayout.__middleware__() == [{&LoadCurrentUser.call/2, [load: :id_only]}]
    end

    test "touches a signed-in user's id: one tokens lookup, no users query" do
      user = create_user()

      {result, queries} =
        capture_queries(fn -> layout_command(:presence_ping, session_server(user)) end)

      assert result.next_action == nil
      assert seen?(user.id)
      assert selects(queries, "tokens") == 1
      assert selects(queries, "users") == 0
    end

    test "with resync it replies with the current count" do
      server = anon_server("TEST-anon-#{System.unique_integer([:positive])}")
      server = Server.Middleware.run(server, AppLayout.__middleware__())
      result = AppLayout.command(:presence_ping, %{resync: true}, server)

      assert %{name: :online_count_updated, params: %{count: count}} = result.next_action
      assert count >= 1
      assert seen?(Auth.actor_key(server))
    end

    test "touches an account-less session's hashed key without any query" do
      server = anon_server("TEST-anon-#{System.unique_integer([:positive])}")
      key = Auth.actor_key(server)
      assert "anon:" <> _ = key

      {_result, queries} = capture_queries(fn -> layout_command(:presence_ping, server) end)

      assert seen?(key)
      assert queries == []
    end

    test "a revoked session is signed out by the layout's middleware and counted as anonymous" do
      user = create_user()
      token = mint_token!(user)
      :ok = AshAuthentication.TokenResource.Actions.revoke(Scrawly.Accounts.Token, token)
      server = session_server(user, token)

      result = layout_command(:presence_ping, server)

      assert "user_id" in session_deletes(result)
      assert seen?(Auth.actor_key(%{server | session: %{}}))
    end
  end
end
