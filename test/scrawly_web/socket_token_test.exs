defmodule ScrawlyWeb.SocketTokenTest do
  @moduledoc """
  QA auth #2/#3 and client C3: the game page no longer holds the session's
  sign-in JWT. It gets a socket-only token (`ScrawlyWeb.SocketToken`) that
  expires, is tied to the session token's jti (so revocation kills it), and is
  refreshed by snapshot replies and after a refused connect. Every revocation
  of a user's tokens tells their sockets to reconnect (T7).
  """
  use ScrawlyWeb.ChannelCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers
  import Scrawly.JsCallTrace, only: [js_calls: 1]

  alias AshAuthentication.TokenResource
  alias Hologram.Server
  alias Scrawly.Accounts
  alias ScrawlyWeb.{SocketToken, UserSocket}
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Pages.{GamePage, HomePage, ProfilePage}
  alias ScrawlyWeb.Pages.GamePage.Commands

  @moduletag :capture_log

  defp register!(password \\ "old-password-1") do
    email = "sock-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_with_password(email, password)
    {email, user}
  end

  defp game_server(user, token), do: run_page_middleware(GamePage, session_server(user, token))

  @me "u1"

  defp member_page(overrides \\ []) do
    state =
      Map.merge(
        %{
          current_user_id: @me,
          players: [%{id: @me, username: "Me"}],
          watchers: [],
          leaving?: false,
          room_code: "ABCD",
          socket_token: "old",
          token_refresh_at: nil,
          channel_connected: true,
          channel_connecting: false
        },
        Map.new(overrides)
      )

    %Hologram.Component{props: %{room_id: "r1"}, state: state}
  end

  defp subscribe!(user), do: ScrawlyWeb.Endpoint.subscribe("user_socket:#{user.id}")

  defp assert_disconnect(user) do
    topic = "user_socket:#{user.id}"
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  defp socket_user(token) do
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket.assigns.user_id
  end

  describe "mint/1 and verify/1" do
    test "a token minted for a valid session opens a socket as that user" do
      {_email, user} = register!()
      token = SocketToken.mint(game_server(user, mint_token!(user)))

      assert SocketToken.verify(token) == {:ok, user.id}
      assert socket_user(token) == user.id
    end

    test "no session, an invalid session or junk gives no user" do
      assert SocketToken.mint(run_page_middleware(GamePage, %Server{session: %{}})) == nil

      for junk <- [nil, 123, "", "garbage"], do: assert(SocketToken.verify(junk) == :error)
    end

    test "the session's sign-in JWT is not accepted by the socket any more" do
      {_email, user} = register!()
      assert socket_user(mint_token!(user)) == nil
    end

    test "it expires after max_age" do
      {_email, user} = register!()
      jwt = mint_token!(user)
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(jwt)

      old =
        Phoenix.Token.sign(ScrawlyWeb.Endpoint, "game socket", %{"u" => user.id, "j" => jti},
          signed_at: System.system_time(:second) - SocketToken.max_age() - 1
        )

      assert SocketToken.verify(old) == :error
    end

    test "revoking the session token kills its socket tokens" do
      {_email, user} = register!()
      jwt = mint_token!(user)
      token = SocketToken.mint(game_server(user, jwt))

      :ok = TokenResource.Actions.revoke(Accounts.Token, jwt)

      assert SocketToken.verify(token) == :error
      assert socket_user(token) == nil
    end
  end

  describe "GamePage" do
    setup do
      creator = create_user()
      room = start_room(creator)
      %{room: room, creator: creator}
    end

    test "init puts a socket token in state, never the session's JWT", %{room: room} do
      {_email, user} = register!()
      jwt = mint_token!(user)

      {component, _server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, game_server(user, jwt))

      token = component.state.socket_token
      assert SocketToken.verify(token) == {:ok, user.id}
      refute token == jwt
      refute inspect(component.state, limit: :infinity, printable_limit: :infinity) =~ jwt
    end

    test "a visitor without a session gets no token", %{room: room} do
      {component, _server} =
        GamePage.init(%{room_id: room.id}, %Hologram.Component{}, anon_server())

      assert component.state.socket_token == ""
    end

    test "every snapshot reply carries a fresh token; the page keeps it", %{room: room} do
      {_email, user} = register!()
      server = game_server(user, mint_token!(user))

      result = Commands.resync_room(%{room_id: room.id}, server)
      assert result.next_action.name == :room_resynced
      assert SocketToken.verify(result.next_action.params.socket_token) == {:ok, user.id}

      anon = Commands.resync_room(%{room_id: room.id}, anon_server())
      assert anon.next_action.params.socket_token == nil
    end

    test ":refresh_socket_token replies a fresh token, or \"\" once signed out" do
      {_email, user} = register!()
      jwt = mint_token!(user)

      result = GamePage.command(:refresh_socket_token, %{}, game_server(user, jwt))
      assert result.next_action.name == :socket_token_refreshed
      assert SocketToken.verify(result.next_action.params.token) == {:ok, user.id}

      :ok = TokenResource.Actions.revoke(Accounts.Token, jwt)
      revoked = GamePage.command(:refresh_socket_token, %{}, game_server(user, jwt))
      assert revoked.next_action.params.token == ""
    end
  end

  describe "GamePage after a refused connect" do
    test "a member asks for a fresh token once per 30 s and reconnects with it" do
      refused = GamePage.action(:game_channel_refused, %{}, member_page())

      assert refused.state.channel_connected == false
      assert refused.next_command.name == :refresh_socket_token

      again = GamePage.action(:game_channel_refused, %{}, %{refused | next_command: nil})
      assert again.next_command == nil

      {connected, calls} =
        js_calls(fn ->
          GamePage.action(:socket_token_refreshed, %{token: "fresh"}, %{again | next_command: nil})
        end)

      assert connected.state.socket_token == "fresh"
      assert {:connectGameChannel, ["fresh", "ABCD"]} in calls
    end

    test "a non-member or a signed-out page doesn't" do
      assert GamePage.action(:game_channel_refused, %{}, member_page(players: [])).next_command ==
               nil

      {result, calls} =
        js_calls(fn ->
          GamePage.action(
            :socket_token_refreshed,
            %{token: ""},
            member_page(channel_connected: false)
          )
        end)

      assert result.state.socket_token == ""
      refute Enum.any?(calls, &(elem(&1, 0) == :connectGameChannel))
    end
  end

  describe "revocations disconnect the user's sockets" do
    test "T7: a password change, and the old socket token no longer connects" do
      {_email, user} = register!()
      jwt = mint_token!(user)
      socket_token = SocketToken.mint(game_server(user, jwt))
      assert socket_user(socket_token) == user.id
      subscribe!(user)

      server = run_page_middleware(ProfilePage, session_server(user, jwt))

      result =
        ProfilePage.command(
          :save_password,
          %{
            current_password: "old-password-1",
            password: "new-password-1",
            password_confirmation: "new-password-1"
          },
          server
        )

      assert result.next_action.name == :password_saved
      assert_disconnect(user)
      assert socket_user(socket_token) == nil
    end

    test "a recovery reset" do
      {email, user} = register!()
      subscribe!(user)

      result =
        HomePage.command(
          :reset_password,
          %{
            email: email,
            recovery_code: user.__metadata__.recovery_code,
            password: "new-password-1",
            password_confirmation: "new-password-1"
          },
          run_page_middleware(HomePage, %Server{session: %{}})
        )

      assert result.next_action.name == :show_recovery_code
      assert_disconnect(user)
    end

    test "signing out (AppLayout :sign_out)" do
      {_email, user} = register!()
      subscribe!(user)

      AppLayout.command(:sign_out, %{}, session_server(user))
      assert_disconnect(user)
    end

    test "upgrading a guest" do
      guest = Accounts.register_as_guest!()
      subscribe!(guest)

      result =
        HomePage.command(
          :register,
          %{
            email: "up-#{System.unique_integer([:positive])}@example.com",
            password: "password123"
          },
          signed_in_server(guest)
        )

      assert result.next_action.name == :show_recovery_code
      assert_disconnect(guest)
    end
  end
end
