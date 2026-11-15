defmodule Scrawly.Accounts.GuestTest do
  use Scrawly.DataCase, async: true

  alias Scrawly.Accounts
  alias Scrawly.Accounts.User

  describe "register_as_guest" do
    test "creates a guest with a generated identity and a verifiable token" do
      guest = Accounts.register_as_guest!()

      assert guest.is_guest == true
      assert String.starts_with?(guest.username, "guest-")
      assert to_string(guest.email) =~ "@guest.scrawly.local"

      token = guest.__metadata__[:token]
      assert is_binary(token)
      assert match?({:ok, _, _}, AshAuthentication.Jwt.verify(token, User))
    end

    test "each guest gets a distinct identity" do
      g1 = Accounts.register_as_guest!()
      g2 = Accounts.register_as_guest!()

      refute g1.id == g2.id
      refute g1.username == g2.username
      refute to_string(g1.email) == to_string(g2.email)
    end

    test "regular created users are not guests" do
      {:ok, user} =
        Ash.create(User, %{email: "real-#{System.unique_integer([:positive])}@example.com"},
          authorize?: false
        )

      assert user.is_guest == false
    end
  end

  describe "guests cannot create rooms" do
    test "the create_room command rejects a guest" do
      guest = Accounts.register_as_guest!()
      server = Scrawly.SessionTestHelpers.signed_in_server(guest)
      assert server.stash.current_user.id == guest.id

      result = ScrawlyWeb.Pages.HomePage.command(:create_room, %{name: "TEST guest"}, server)

      # The form says why (create-room-form); no room is created.
      assert result.next_action.name == :create_room_failed

      assert result.next_action.params == %{
               field: nil,
               message: "register an account to create rooms"
             }
    end
  end

  describe "upgrade_guest" do
    test "turns a guest into a real account in place" do
      guest = Accounts.register_as_guest!()
      email = "upgraded-#{System.unique_integer([:positive])}@example.com"

      {:ok, upgraded} = Accounts.upgrade_guest(guest, %{email: email, password: "password123"})

      assert upgraded.id == guest.id
      assert upgraded.is_guest == false
      assert to_string(upgraded.email) == email
      assert is_binary(upgraded.hashed_password)

      assert match?(
               {:ok, _, _},
               AshAuthentication.Jwt.verify(upgraded.__metadata__[:token], User)
             )

      assert match?({:ok, _}, Accounts.sign_in_with_password(email, "password123"))
    end

    test "rejects a password shorter than 8 characters" do
      guest = Accounts.register_as_guest!()
      email = "short-#{System.unique_integer([:positive])}@example.com"

      assert {:error, _} = Accounts.upgrade_guest(guest, %{email: email, password: "short"})
    end
  end
end
