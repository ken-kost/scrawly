defmodule ScrawlyWeb.Pages.RoomLinkPageTest do
  @moduledoc """
  The short room link `/r/:code` (invites): its middleware redirects every
  request, so the page never renders. A known code (any case) opens its game
  page; a signed-out visitor goes through `/guest`, which accepts the game
  path as `return_to` and lands them there as a guest. An unknown or ended
  room, or too many lookups, goes to Home with a notice its code field shows.
  """
  use ScrawlyWeb.ConnCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers

  alias Hologram.Component
  alias Hologram.Server
  alias Scrawly.Accounts.Throttle
  alias Scrawly.Games
  alias ScrawlyWeb.Auth
  alias ScrawlyWeb.Pages.{HomePage, RoomLinkPage}

  @moduletag :capture_log

  # A first load of /r/<code>: the page's whole middleware chain, as Hologram
  # runs it for the request.
  defp open(code, server) do
    run_page_middleware(RoomLinkPage, %{server | path: "/r/" <> code})
  end

  defp anon do
    %Server{session: %{}, session_id: "anon-link-#{System.unique_integer([:positive])}"}
  end

  defp location(server), do: server.response_headers["location"]

  defp unique_ip do
    n = System.unique_integer([:positive])
    {10, 30, rem(div(n, 256), 256), rem(n, 256)}
  end

  defp home_after(server) do
    # The next request's session: what the redirect's session writes leave.
    session =
      Enum.reduce(Server.get_session_ops(server), server.session, fn
        {key, {:put, value}}, acc -> Map.put(acc, key, value)
        {key, :delete}, acc -> Map.delete(acc, key)
      end)

    home_server = run_page_middleware(HomePage, %Server{session: session, session_id: "home"})
    {component, home_server} = HomePage.init(%{}, %Component{}, home_server)
    {component.state, home_server}
  end

  setup do
    creator = create_user()
    %{room: start_room(creator), creator: creator}
  end

  describe "a known code" do
    test "takes a signed-in visitor to the game page, whatever the case", %{room: room} do
      user = create_user()

      for code <- [room.code, String.downcase(room.code)] do
        result = open(code, signed_in_server(user, load: :id_only))
        assert result.status == 302
        assert location(result) == "/game/" <> room.id
      end
    end

    test "takes a guest straight to the game page", %{room: room} do
      guest = Scrawly.Accounts.register_as_guest!()
      result = open(room.code, session_server(guest))
      assert location(result) == "/game/" <> room.id
    end

    test "a client-side navigation reads the code from the page request's query", %{room: room} do
      server = %{
        signed_in_server(create_user(), load: :id_only)
        | path: "/hologram/page/Elixir.ScrawlyWeb.Pages.RoomLinkPage",
          query: %{"code" => String.downcase(room.code)}
      }

      result = run_page_middleware(RoomLinkPage, server)
      assert location(result) == "/game/" <> room.id
    end

    test "a signed-out visitor ends up in the room as a guest", %{conn: conn, room: room} do
      result = open(String.downcase(room.code), anon())
      assert result.status == 302
      to = location(result)
      assert to == "/guest?return_to=%2Fgame%2F" <> room.id

      # /guest accepts the game path: a new guest session, then the room.
      conn =
        conn
        |> Map.put(:remote_ip, unique_ip())
        |> init_test_session(%{})
        |> get(to)

      assert redirected_to(conn) == "/game/" <> room.id
      guest_id = get_session(conn, :user_id)
      token = get_session(conn, :user_token)

      assert {:ok, ^guest_id, _row} = Auth.verify_session_token(guest_id, token)
      assert {:ok, %{is_guest: true}} = Auth.load_user(guest_id)

      # The game page, with that session, then joins the guest as a player
      # (the lobby has room).
      server =
        run_page_middleware(ScrawlyWeb.Pages.GamePage, %Server{
          session: %{"user_id" => guest_id, "user_token" => token},
          session_id: "guest-tab"
        })

      {component, _server} =
        ScrawlyWeb.Pages.GamePage.init(%{room_id: room.id}, %Component{}, server)

      assert component.state.room_status == :lobby
      assert component.state.watching? == false
      assert component.next_action.name == :mounted
      assert component.next_action.params.join == :player
    end
  end

  describe "no room" do
    test "an unknown code goes to Home, which says so once", %{room: room} do
      unknown = if room.code == "ZZZZ22", do: "ZZZZ23", else: "ZZZZ22"
      result = open(String.downcase(unknown), anon())

      assert result.status == 302
      assert location(result) == "/"

      {state, home_server} = home_after(result)
      assert state.room_code_error == "no room with that code"
      assert state.room_code_input == unknown
      assert Server.get_session_ops(home_server)["room_code_notice"] == :delete
    end

    test "an ended room is no room", %{room: room} do
      stop_room(room.id)
      Games.dissolve_room(room.id)

      result = open(room.code, signed_in_server(create_user(), load: :id_only))
      assert location(result) == "/"
      assert {%{room_code_error: "no room with that code"}, _} = home_after(result)
    end

    test "a malformed code is no room either, and isn't put back in the field" do
      for code <- ["", "ab", "hello-world", "%zz", "AB0CD7"] do
        result = open(code, anon())
        assert location(result) == "/", code

        assert {%{room_code_error: "no room with that code", room_code_input: ""}, _} =
                 home_after(result)
      end
    end

    test "past the lookup cap: Home says to wait, even for a known code", %{room: room} do
      server = anon()
      {max, _window} = Throttle.limit(:room_code)
      for _ <- 1..max, do: open("ZZZZ22", server)

      result = open(room.code, server)
      assert location(result) == "/"
      assert {%{room_code_error: "too many tries, wait a minute"}, _} = home_after(result)
    end

    test "Home's code field and the short link share the cap", %{room: room} do
      server = anon()
      {max, _window} = Throttle.limit(:room_code)

      for _ <- 1..max do
        HomePage.command(:join_by_code, %{code: "zzzz22"}, run_page_middleware(HomePage, server))
      end

      assert location(open(room.code, server)) == "/"
    end
  end

  test "the page renders nothing of its own and denies every command" do
    assert RoomLinkPage.__route__() == "/r/:code"

    result = RoomLinkPage.command(:anything, %{}, anon())
    assert result.next_action.name == :command_denied
  end
end
