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
      server = %Hologram.Server{session: %{"user_id" => guest.id}}

      result = ScrawlyWeb.Pages.HomePage.command(:create_room, %{}, server)

      assert result.next_action == nil
    end
  end
end
