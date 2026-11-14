defmodule ScrawlyWeb.Pages.CurrentUserPagesTest do
  @moduledoc """
  The session user is checked once per request (LoadCurrentUser) and loaded at
  most once per render: pages, AppLayout and GamePage commands all read the
  middleware's stash.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers

  alias AshAuthentication.TokenResource
  alias Hologram.{Component, Server}
  alias Scrawly.Accounts
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Middleware.LoadCurrentUser

  alias ScrawlyWeb.Pages.{
    GamePage,
    GameScorePage,
    HomePage,
    PastGamesPage,
    ProfilePage
  }

  @moduletag :capture_log

  # What Hologram does for a page request: the page's middleware chain, its
  # init, then the layout's init with the struct the page's init returned.
  defp render(page, params, server) do
    server = run_page_middleware(page, server)
    assert server.status == nil

    component = %Component{props: params}

    {page_component, server} =
      case page.init(params, component, server) do
        {%Component{} = c, %Server{} = s} -> {c, s}
        %Component{} = c -> {c, server}
      end

    layout = AppLayout.init(%{}, %Component{}, server)
    %{page: page_component.state, layout: layout.state, server: server}
  end

  defp pages(room, user) do
    [
      {HomePage, %{}},
      {GamePage, %{room_id: room.id}},
      {ProfilePage, %{}},
      {GameScorePage, %{game_id: Ecto.UUID.generate()}},
      {PastGamesPage, %{}}
    ]
    |> Enum.reject(fn {page, _} -> page == ProfilePage and user == nil end)
  end

  defp holds_user_record?(state) do
    dump = inspect(state, limit: :infinity, printable_limit: :infinity)
    dump =~ "Scrawly.Accounts.User" or dump =~ "hashed_password"
  end

  setup do
    host = create_user()
    room = start_room(host)
    %{room: room}
  end

  describe "the middleware is on every page" do
    test "all five pages run LoadCurrentUser first; GamePage in :id_only mode" do
      load = &LoadCurrentUser.call/2

      for page <- [HomePage, ProfilePage, GameScorePage, PastGamesPage] do
        assert [{^load, []} | _] = page.__middleware__()
        assert page.__layout_module__() == AppLayout
      end

      assert GamePage.__middleware__() == [{load, [load: :id_only]}]
      assert GamePage.__layout_module__() == AppLayout
    end

    test "AppLayout without the middleware fails with a message naming it" do
      error =
        assert_raise ArgumentError, fn ->
          AppLayout.init(%{}, %Component{}, %Server{session: %{"user_id" => "x"}})
        end

      assert error.message =~ "ScrawlyWeb.Middleware.LoadCurrentUser"
      assert error.message =~ "use ScrawlyWeb.Page"
    end
  end

  describe "queries per render" do
    test "signed in (registered or guest): one tokens lookup and one users SELECT", %{room: room} do
      for user <- [create_user(), Accounts.register_as_guest!()] do
        for {page, params} <- pages(room, user) do
          server = session_server(user)

          {result, queries} = capture_queries(fn -> render(page, params, server) end)

          assert selects(queries, "tokens") == 1, "#{inspect(page)}: #{inspect(queries)}"
          assert selects(queries, "users") == 1, "#{inspect(page)}: #{inspect(queries)}"
          assert result.layout.authenticated == true
          assert result.layout.user_id == user.id
          assert result.server.user_id == user.id
        end
      end
    end

    test "signed out: no tokens lookup and no users SELECT", %{room: room} do
      for {page, params} <- pages(room, nil) do
        {result, queries} =
          capture_queries(fn -> render(page, params, %Server{session: %{}}) end)

        assert selects(queries, "tokens") == 0, "#{inspect(page)}: #{inspect(queries)}"
        assert selects(queries, "users") == 0, "#{inspect(page)}: #{inspect(queries)}"
        assert result.layout.authenticated == false
        assert result.server.user_id == nil
      end
    end

    test "a revoked session renders signed out and drops its session keys", %{room: room} do
      user = create_user()
      token = mint_token!(user)
      :ok = TokenResource.Actions.revoke(Accounts.Token, token)

      for {page, params} <- pages(room, nil) do
        result = render(page, params, %{session_server(user, token) | user_id: user.id})

        assert result.layout.authenticated == false
        assert result.server.user_id == nil
        assert "user_id" in session_deletes(result.server)
        assert "user_token" in session_deletes(result.server)
      end
    end

    test "no page or layout state holds a user record", %{room: room} do
      user = create_user()

      for {page, params} <- pages(room, user) do
        result = render(page, params, session_server(user))

        refute holds_user_record?(result.page), inspect(page)
        refute holds_user_record?(result.layout), inspect(page)
      end
    end

    test "GamePage stashes the user it loaded for the layout", %{room: room} do
      user = create_user()
      result = render(GamePage, %{room_id: room.id}, session_server(user))

      assert result.server.stash.current_user.id == user.id
      assert result.page.current_user_username == user.username
      assert result.layout.username == user.username
    end
  end

  describe "commands" do
    test "a GamePage command runs one tokens lookup and no users SELECT", %{room: room} do
      user = create_user()
      server = session_server(user)

      {result, queries} =
        capture_queries(fn ->
          server = run_page_middleware(GamePage, server)
          GamePage.command(:resync_room, %{room_id: room.id}, server)
        end)

      assert %Server{} = result
      assert selects(queries, "tokens") == 1
      assert selects(queries, "users") == 0
    end

    test "an anonymous GamePage command runs neither", %{room: room} do
      {_result, queries} =
        capture_queries(fn ->
          server = run_page_middleware(GamePage, %Server{session: %{}, session_id: "anon-1"})
          GamePage.command(:resync_room, %{room_id: room.id}, server)
        end)

      assert selects(queries, "tokens") == 0
      assert selects(queries, "users") == 0
    end

    test "AppLayout :read_online_count runs no users or tokens query" do
      user = create_user()

      {_result, queries} =
        capture_queries(fn ->
          AppLayout.command(:read_online_count, %{}, session_server(user))
        end)

      assert selects(queries, "tokens") == 0
      assert selects(queries, "users") == 0
    end

    test "AppLayout theme writes reach the account only with a valid session token" do
      user = create_user()
      token = mint_token!(user)

      AppLayout.command(:save_theme, %{dark_mode: true}, session_server(user, token))
      AppLayout.command(:save_accent, %{accent: "orange"}, session_server(user, token))
      assert %{dark_mode: true, accent_color: :orange} = reload_user!(user)

      :ok = TokenResource.Actions.revoke(Accounts.Token, token)

      result =
        AppLayout.command(:save_theme, %{dark_mode: false}, session_server(user, token))

      AppLayout.command(:save_accent, %{accent: "yellow"}, session_server(user, token))
      assert %{dark_mode: true, accent_color: :orange} = reload_user!(user)
      # The browser's own theme still changes.
      assert session_puts(result)["dark_mode"] == false
    end
  end

  describe "the header" do
    defp layout_state(server) do
      server = LoadCurrentUser.call(server, [])
      AppLayout.init(%{}, %Component{}, server).state
    end

    defp with_theme(server, dark, accent) do
      %{
        server
        | session: Map.merge(server.session, %{"dark_mode" => dark, "accent_color" => accent})
      }
    end

    test "a registered user: handle, avatar and the account's theme" do
      user = create_user()

      {:ok, user} =
        Accounts.update_profile(user, %{
          username: "TESTheader",
          avatar_id: "a3",
          avatar_color: "7"
        })

      {:ok, user} = Accounts.update_accent_color(user, :orange)
      {:ok, _user} = Accounts.update_dark_mode(user, true)

      state = layout_state(session_server(user) |> with_theme(false, "yellow"))

      assert state.authenticated == true
      assert state.username == "TESTheader"
      assert state.avatar_id == "a3"
      assert state.avatar_color == "7"
      # dark = account || session; a valid account accent wins.
      assert state.dark_mode == true
      assert state.accent == :orange
    end

    test "an account with the default theme: dark follows the session, its accent wins" do
      user = create_user()
      state = layout_state(session_server(user) |> with_theme(true, "yellow"))

      assert state.dark_mode == true
      assert state.accent == :purple
    end

    test "a guest is shown with its guest handle" do
      guest = Accounts.register_as_guest!()
      state = layout_state(session_server(guest))

      assert state.authenticated == true
      assert state.username == guest.username
    end

    test "a signed-out visitor gets the defaults and the session's theme" do
      state = layout_state(%Server{session: %{"dark_mode" => true, "accent_color" => "yellow"}})

      assert state.authenticated == false
      assert state.username == nil
      assert state.user_id == nil
      assert state.dark_mode == true
      assert state.accent == :yellow

      assert layout_state(%Server{session: %{"accent_color" => "nope"}}).accent == :purple
    end
  end
end
