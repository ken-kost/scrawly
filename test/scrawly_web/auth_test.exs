defmodule ScrawlyWeb.AuthTest do
  use Scrawly.DataCase, async: true

  import Scrawly.RoomTestHelpers, only: [create_user: 0, server_for: 1, anon_server: 1]

  alias ScrawlyWeb.Auth

  @moduletag :capture_log

  describe "user_id/1" do
    test "reads the session user id" do
      assert Auth.user_id(%Hologram.Server{session: %{"user_id" => "abc"}}) == "abc"
    end

    test "is nil without a session user" do
      assert Auth.user_id(%Hologram.Server{}) == nil
    end
  end

  describe "current_user/1" do
    test "loads the session user" do
      user = create_user()

      assert {:ok, %Scrawly.Accounts.User{id: id}} = Auth.current_user(server_for(user))
      assert id == user.id
    end

    test "is unauthenticated without a session user" do
      assert Auth.current_user(%Hologram.Server{}) == {:error, :unauthenticated}
    end

    test "is unauthenticated for an unknown id" do
      server = %Hologram.Server{session: %{"user_id" => Ecto.UUID.generate()}}
      assert Auth.current_user(server) == {:error, :unauthenticated}
    end

    test "is unauthenticated (and doesn't raise) for a non-UUID id" do
      server = %Hologram.Server{session: %{"user_id" => "Watcher"}}
      assert Auth.current_user(server) == {:error, :unauthenticated}
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
      assert Auth.actor_key(%Hologram.Server{}) == nil
    end
  end

  describe "deny/3" do
    test "replies with :command_denied and changes nothing else" do
      server = %Hologram.Server{session: %{"user_id" => "abc"}, session_id: "s1"}

      result = Auth.deny(server, :start_game, :not_creator)

      assert result.next_action.name == :command_denied
      assert result.next_action.params == %{command: :start_game, reason: :not_creator}
      assert result.broadcasts == []
      assert result.session == server.session
      assert result.__meta__ == server.__meta__
    end
  end
end
