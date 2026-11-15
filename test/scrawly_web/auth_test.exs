defmodule ScrawlyWeb.AuthTest do
  use Scrawly.DataCase, async: true

  import Scrawly.RoomTestHelpers, only: [create_user: 0, server_for: 1, anon_server: 1]
  import Scrawly.SessionTestHelpers

  alias AshAuthentication.TokenResource
  alias Hologram.Server
  alias Scrawly.Accounts
  alias ScrawlyWeb.Auth

  @moduletag :capture_log

  describe "user_id/1" do
    test "reads the id the page middleware stashed" do
      assert Auth.user_id(%Server{stash: %{current_user_id: "abc"}}) == "abc"
      # A stashed nil means signed out; the session is not consulted again.
      assert Auth.user_id(%Server{stash: %{current_user_id: nil}, session: %{"user_id" => "x"}}) ==
               nil
    end

    test "without a stash it checks the session token (layout commands)" do
      user = create_user()

      assert Auth.user_id(session_server(user)) == user.id
    end

    test "a bare session user_id without a valid token is nobody" do
      user = create_user()

      assert Auth.user_id(%Server{session: %{"user_id" => user.id}}) == nil

      assert Auth.user_id(%Server{session: %{"user_id" => user.id, "user_token" => "junk"}}) ==
               nil
    end

    test "is nil without a session user" do
      assert Auth.user_id(%Server{}) == nil
    end
  end

  describe "current_user/1" do
    test "reads the user the page middleware stashed, without a query" do
      user = create_user()
      server = signed_in_server(user)

      assert {:ok, %Accounts.User{id: id}} = Auth.current_user(server)
      assert id == user.id
      assert server.stash.current_user.id == user.id
    end

    test "loads the stashed id's user in :id_only mode" do
      user = create_user()

      assert {:ok, %Accounts.User{id: id}} = Auth.current_user(server_for(user))
      assert id == user.id
    end

    test "a stashed nil is unauthenticated" do
      server = %Server{stash: %{current_user_id: nil, current_user: nil}}
      assert Auth.current_user(server) == {:error, :unauthenticated}
    end

    test "without a stash it checks the session token" do
      user = create_user()

      assert {:ok, %Accounts.User{id: id}} = Auth.current_user(session_server(user))
      assert id == user.id

      assert Auth.current_user(%Server{session: %{"user_id" => user.id}}) ==
               {:error, :unauthenticated}
    end

    test "is unauthenticated without a session user" do
      assert Auth.current_user(%Server{}) == {:error, :unauthenticated}
    end

    test "is unauthenticated for an unknown id" do
      server = %Server{stash: %{current_user_id: Ecto.UUID.generate()}}
      assert Auth.current_user(server) == {:error, :unauthenticated}
    end

    test "is unauthenticated (and doesn't raise) for a non-UUID id" do
      server = %Server{stash: %{current_user_id: "Watcher"}}
      assert Auth.current_user(server) == {:error, :unauthenticated}
    end
  end

  describe "verify_session_token/2" do
    test "accepts a stored, unrevoked token of that user" do
      user = create_user()
      token = mint_token!(user)

      assert {:ok, id, %Accounts.Token{} = row} = Auth.verify_session_token(user.id, token)
      assert id == user.id
      assert row.subject == "user?id=#{user.id}"
    end

    test "rejects another user's token, a revoked one and malformed input" do
      user = create_user()
      other = create_user()
      token = mint_token!(user)

      assert Auth.verify_session_token(other.id, token) == :error
      assert Auth.verify_session_token(user.id, "junk") == :error
      assert Auth.verify_session_token(user.id, nil) == :error
      assert Auth.verify_session_token(nil, token) == :error
      assert Auth.verify_session_token("Watcher", token) == :error

      :ok = TokenResource.Actions.revoke(Accounts.Token, token)
      assert Auth.verify_session_token(user.id, token) == :error
    end

    test "rejects a token that was never stored" do
      user = create_user()
      # Signed like a real one but with a jti the tokens table never saw.
      {:ok, unstored, _claims} =
        Joken.generate_and_sign(
          %{},
          %{"sub" => "user?id=#{user.id}", "jti" => Ecto.UUID.generate()},
          Joken.Signer.create("HS256", "x")
        )

      assert Auth.verify_session_token(user.id, unstored) == :error
    end
  end

  describe "put_session_user/3 and put_fresh_token/2" do
    test "write a session that passes the check, Hologram's identity and the stash" do
      user = create_user()

      server = Auth.put_session_user(%Server{}, user, mint_token!(user))
      assert_signed_in_as(server, user)
      assert server.stash.current_user_id == user.id

      assert {:ok, renewed} = Auth.put_fresh_token(%Server{}, user)
      token = assert_signed_in_as(renewed, user)
      assert session_puts(renewed)["user_token"] == token
    end
  end

  describe "actor_key/1" do
    test "is the user id when there is a session user" do
      user = create_user()
      assert Auth.actor_key(server_for(user)) == user.id
    end

    test "is a hashed, stable key for an account-less session" do
      key = Auth.actor_key(anon_server("session-a"))

      assert "anon:" <> hex = key
      assert hex =~ ~r/\A[0-9a-f]{16}\z/
      refute key =~ "session-a"
      assert Auth.actor_key(anon_server("session-a")) == key
      refute Auth.actor_key(anon_server("session-b")) == key
    end

    test "is nil without a user or a session id" do
      assert Auth.actor_key(%Server{}) == nil
    end
  end

  describe "deny/3" do
    test "replies with :command_denied and changes nothing else" do
      server = %Server{session: %{"user_id" => "abc"}, session_id: "s1"}

      result = Auth.deny(server, :start_game, :not_creator)

      assert result.next_action.name == :command_denied
      assert result.next_action.params == %{command: :start_game, reason: :not_creator}
      assert result.broadcasts == []
      assert result.session == server.session
      assert result.__meta__ == server.__meta__
    end
  end
end
