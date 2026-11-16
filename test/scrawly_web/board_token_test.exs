defmodule ScrawlyWeb.BoardTokenTest do
  @moduledoc """
  #42: the home board knows who draws. HomePage mints a board token
  (`ScrawlyWeb.BoardToken`) naming the caller's actor key, in a command's
  reply only (never in rendered or snapshotted state); `ScrawlyWeb.UserSocket`
  verifies it into `board_key`, which only the board's channel reads. An
  account's token dies with its session token, an anonymous visitor's when it
  expires. A socket without one watches but can't draw, and the page asks for
  a fresh token when the board refuses it.
  """
  use ScrawlyWeb.ChannelCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers
  import Scrawly.JsCallTrace, only: [js_calls: 1]

  alias AshAuthentication.TokenResource
  alias Hologram.{Component, Server}
  alias Scrawly.Accounts
  alias Scrawly.Games.DemoBoardServer
  alias ScrawlyWeb.{Auth, BoardToken, DemoBoardChannel, SocketToken, UserSocket}
  alias ScrawlyWeb.Pages.HomePage

  @moduletag :capture_log

  defp register! do
    email = "board-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_with_password(email, "password-123")
    user
  end

  defp home_server(%Server{} = server), do: run_page_middleware(HomePage, server)

  defp anon_home do
    home_server(anon_server("TEST-board-#{System.unique_integer([:positive])}"))
  end

  defp minted(server) do
    result = HomePage.command(:board_token, %{}, server)
    assert result.next_action.name == :board_token_ready
    result.next_action.params.board_token
  end

  defp connect!(params) do
    {:ok, socket} = connect(UserSocket, params)
    socket
  end

  describe "mint/1 and verify/1" do
    test "an anonymous visitor's token names their actor key" do
      server = anon_home()
      token = minted(server)

      assert {:ok, "anon:" <> _ = key} = BoardToken.verify(token)
      assert key == Auth.actor_key(server)
      refute BoardToken.account_key?(key)
    end

    test "an account's (a guest's too) names its id, and dies with the session token" do
      user = register!()
      jwt = mint_token!(user)
      token = minted(home_server(session_server(user, jwt)))
      assert BoardToken.verify(token) == {:ok, user.id}
      assert BoardToken.account_key?(user.id)

      guest = Accounts.register_as_guest!()
      assert BoardToken.verify(minted(signed_in_server(guest))) == {:ok, guest.id}

      :ok = TokenResource.Actions.revoke(Accounts.Token, jwt)
      assert BoardToken.verify(token) == :error
    end

    test "it expires after max_age" do
      key = Auth.actor_key(anon_home())

      old =
        Phoenix.Token.sign(ScrawlyWeb.Endpoint, "demo board socket", %{"k" => key},
          signed_at: System.system_time(:second) - BoardToken.max_age() - 1
        )

      assert BoardToken.verify(old) == :error
      assert BoardToken.max_age() < SocketToken.max_age()
    end

    test "junk, a game socket token or a forged claim is no board token" do
      user = register!()
      game_token = SocketToken.mint(home_server(session_server(user)))

      for junk <- [nil, 1, "", "garbage", game_token] do
        assert BoardToken.verify(junk) == :error
      end

      # Signed with the board's salt but naming an account without a live
      # session token, or a key that is neither.
      for claims <- [%{"k" => user.id}, %{"k" => user.id, "j" => "nope"}, %{"k" => "x"}] do
        token = Phoenix.Token.sign(ScrawlyWeb.Endpoint, "demo board socket", claims)
        assert BoardToken.verify(token) == :error, inspect(claims)
      end

      # And a board token opens no game socket.
      assert SocketToken.verify(minted(home_server(session_server(user)))) == :error
    end

    test "no actor key, no token" do
      assert BoardToken.mint(home_server(%Server{session: %{}})) == nil
    end
  end

  describe "UserSocket" do
    test "a board token gives the socket a board key, never a user" do
      server = anon_home()
      socket = connect!(%{"board_token" => minted(server)})

      assert socket.assigns.board_key == Auth.actor_key(server)
      assert socket.assigns.user_id == nil
      assert UserSocket.id(socket) == nil, "anonymous sockets share no id"
    end

    test "an account's board socket has the user's socket id, so a revocation closes it" do
      user = register!()
      socket = connect!(%{"board_token" => minted(home_server(session_server(user)))})

      assert socket.assigns.board_key == user.id
      assert socket.assigns.user_id == nil
      assert UserSocket.id(socket) == "user_socket:#{user.id}"

      ScrawlyWeb.Endpoint.subscribe("user_socket:#{user.id}")
      Auth.disconnect_sockets(user.id)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "no token or a bad one: no board key" do
      for params <- [%{}, %{"board_token" => "nope"}, %{"board_token" => 5}, %{"demo" => "true"}] do
        assert connect!(params).assigns.board_key == nil
      end
    end

    test "with both tokens, an account's board key must be the game token's user" do
      user = register!()
      other = register!()
      game = SocketToken.mint(home_server(session_server(user)))

      same =
        connect!(%{"token" => game, "board_token" => minted(home_server(session_server(user)))})

      assert {same.assigns.user_id, same.assigns.board_key} == {user.id, user.id}

      mixed =
        connect!(%{"token" => game, "board_token" => minted(home_server(session_server(other)))})

      assert {mixed.assigns.user_id, mixed.assigns.board_key} == {user.id, nil}
    end

    test "through the real socket, the token's key owns the strokes it draws" do
      DemoBoardServer.clear()
      on_exit(fn -> DemoBoardServer.clear() end)

      server = anon_home()
      socket = connect!(%{"board_token" => minted(server)})
      {:ok, %{draw: true}, socket} = subscribe_and_join(socket, DemoBoardChannel, "demo:board")

      stroke = %{
        "stroke_id" => "d-tok-1",
        "path" => "M 1 1 L 2 2",
        "color" => "#000000",
        "width" => 2
      }

      ref = push(socket, "stroke_complete", stroke)
      assert_reply ref, :ok
      assert_push "stroke", %{stroke_id: "d-tok-1", mine: true}

      key = Auth.actor_key(server)
      assert [%{stroke_id: "d-tok-1", owner: ^key}] = DemoBoardServer.get_strokes()

      {:ok, %{draw: false}, watcher} =
        subscribe_and_join(connect!(%{}), DemoBoardChannel, "demo:board")

      ref = push(watcher, "stroke_complete", %{stroke | "stroke_id" => "d-tok-2"})
      assert_reply ref, :error, %{reason: "unauthorized"}
    end
  end

  describe "HomePage" do
    test "init puts no token in state or in its queued action" do
      {component, _server} = HomePage.init(%{}, %Component{}, anon_home())

      assert component.state.can_undo == false
      refute inspect(component, limit: :infinity, printable_limit: :infinity) =~ "SFMyNTY"
      assert component.next_action.name == :connect_lobby
    end

    test "the token goes from the command's reply straight to demo_board.mjs" do
      token = minted(anon_home())
      component = %Component{state: %{can_undo: false}}

      {result, calls} =
        js_calls(fn -> HomePage.action(:board_token_ready, %{board_token: token}, component) end)

      assert calls == [connectDemoBoard: [token]]
      assert result == component, "nothing kept"

      for junk <- [nil, "", 7] do
        {_result, calls} =
          js_calls(fn -> HomePage.action(:board_token_ready, %{board_token: junk}, component) end)

        assert calls == [connectDemoBoard: [nil]]
      end
    end

    test "a refused board asks for a fresh token at most every 30 s" do
      component = %Component{state: %{board_token_at: nil}}
      asked = HomePage.action(:board_token_refused, %{}, component)
      assert asked.next_command.name == :board_token

      again = HomePage.action(:board_token_refused, %{}, %{asked | next_command: nil})
      assert again.next_command == nil

      long_ago = %{again | state: %{board_token_at: asked.state.board_token_at - 30_000}}

      assert HomePage.action(:board_token_refused, %{}, long_ago).next_command.name ==
               :board_token
    end

    test "undo goes to the board; the board tells whether there is anything to undo" do
      component = %Component{state: %{can_undo: false}}
      {result, calls} = js_calls(fn -> HomePage.action(:undo_drawing, %{}, component) end)
      assert calls == [undoBoard: []]
      assert result == component

      on = HomePage.action(:undo_available, %{available: true}, component)
      assert on.state.can_undo == true
      assert HomePage.action(:undo_available, %{available: "yes"}, on).state.can_undo == false
      assert HomePage.action(:undo_available, %{}, on).state.can_undo == false
    end
  end
end
