defmodule ScrawlyWeb.RoomCodesTest do
  @moduledoc """
  Room codes typed on Home or opened as `/r/:code` (invites): normalizing and
  checking the input, the lookup (any case, ended rooms unknown), the
  per-visitor lookup cap shared by both entry points, where a found room
  opens, and the short link's notice for Home.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Server
  alias Scrawly.Accounts.Throttle
  alias Scrawly.Games
  alias Scrawly.Games.Room
  alias ScrawlyWeb.{Auth, RoomCodes}

  @moduletag :capture_log

  defp fresh_anon, do: anon_server("anon-codes-#{System.unique_integer([:positive])}")

  describe "normalize/1 and check/1" do
    test "input is trimmed, its spaces dropped and uppercased" do
      assert RoomCodes.normalize("  ab2 cd7\n") == "AB2CD7"
      assert RoomCodes.normalize("45cvx7") == "45CVX7"
      assert RoomCodes.normalize(nil) == ""
      assert RoomCodes.normalize(123) == ""
    end

    test "a code is 6 characters of A-Z and 2-7" do
      assert RoomCodes.check("AB2CD7") == :ok
      assert RoomCodes.check("") == {:error, :empty}
      assert RoomCodes.check("AB2") == {:error, :length}
      assert RoomCodes.check("AB2CD77") == {:error, :length}
      # 0, 1, 8 and 9 are never in a code; neither is anything else.
      for code <- ["AB0CD7", "AB1CD7", "AB8CD7", "AB9CD7", "AB-CD7", "ABÉCD7", "ab2cd7"] do
        assert RoomCodes.check(code) == {:error, :characters}, code
      end

      assert RoomCodes.check(nil) == {:error, :empty}
    end

    test "every generated room code passes the check" do
      for _ <- 1..2_000 do
        code = Room.generate_code()
        assert RoomCodes.check(code) == :ok, code
      end
    end

    test "messages" do
      assert RoomCodes.message(:empty) == "type a room code"
      assert RoomCodes.message(:length) == "room codes have 6 characters"
      assert RoomCodes.message(:characters) == "room codes use letters and the digits 2-7"
      assert RoomCodes.message(:not_found) == "no room with that code"
      assert RoomCodes.message(:throttled) == "too many tries, wait a minute"
    end
  end

  describe "lookup/2" do
    setup do
      creator = create_user()
      %{room: start_room(creator), creator: creator}
    end

    test "finds an open room by its code, in any case and with spaces around", %{room: room} do
      assert RoomCodes.lookup(fresh_anon(), room.code) == {:ok, room.id}
      assert RoomCodes.lookup(fresh_anon(), String.downcase(room.code)) == {:ok, room.id}

      assert RoomCodes.lookup(fresh_anon(), "  " <> String.downcase(room.code) <> " ") ==
               {:ok, room.id}
    end

    test "an unknown code, or a room that has ended, is not found", %{room: room} do
      unknown = if room.code == "ZZZZ22", do: "ZZZZ23", else: "ZZZZ22"
      assert RoomCodes.lookup(fresh_anon(), unknown) == {:error, :not_found}

      stop_room(room.id)
      Games.dissolve_room(room.id)
      assert RoomCodes.lookup(fresh_anon(), room.code) == {:error, :not_found}
    end

    test "malformed input is refused without counting a lookup" do
      server = fresh_anon()
      key = Auth.actor_key(server)

      assert RoomCodes.lookup(server, "") == {:error, :empty}
      assert RoomCodes.lookup(server, "AB2") == {:error, :length}
      assert RoomCodes.lookup(server, "AB0CD7") == {:error, :characters}
      assert RoomCodes.lookup(server, %{code: "x"}) == {:error, :empty}
      assert Throttle.attempts(:room_code, key) == 0
    end

    test "a visitor gets 10 lookups a minute, found or not; others are unaffected", %{
      room: room
    } do
      {max, window} = Throttle.limit(:room_code)
      assert {max, window} == {10, 60_000}

      server = fresh_anon()

      for i <- 1..max do
        code = if rem(i, 2) == 0, do: room.code, else: "ZZZZ22"
        assert {_ok_or_error, _} = RoomCodes.lookup(server, code)
      end

      assert RoomCodes.lookup(server, room.code) == {:error, :throttled}
      assert RoomCodes.lookup(fresh_anon(), room.code) == {:ok, room.id}
    end

    test "a signed-in visitor is capped by user, whatever the session", %{room: room} do
      user = create_user()

      for _ <- 1..10, do: assert({:ok, _} = RoomCodes.lookup(server_for(user), room.code))

      other_session = %{server_for(user) | session_id: "another-tab-session"}
      assert RoomCodes.lookup(other_session, room.code) == {:error, :throttled}
    end
  end

  describe "entry_path/2" do
    test "a signed-in visitor (a guest too) opens the game page" do
      user = create_user()
      assert RoomCodes.entry_path(server_for(user), "r-1") == "/game/r-1"
    end

    test "a signed-out visitor becomes a guest on the way, returning to the game page" do
      id = Ecto.UUID.generate()
      path = RoomCodes.entry_path(fresh_anon(), id)

      assert path == "/guest?return_to=%2Fgame%2F" <> id
      assert URI.decode_query(URI.parse(path).query) == %{"return_to" => "/game/" <> id}
    end
  end

  describe "put_notice/3 and take_notice/1" do
    test "a short link's failure is shown once on Home, with a well-formed code" do
      server = RoomCodes.put_notice(%Server{}, :not_found, "zzzz22")

      assert {server, %{message: "no room with that code", code: "ZZZZ22"}} =
               RoomCodes.take_notice(server)

      assert {_server, nil} = RoomCodes.take_notice(server)
    end

    test "throttled; other reasons say not found; a malformed code isn't kept" do
      assert {_, %{message: "too many tries, wait a minute", code: ""}} =
               %Server{}
               |> RoomCodes.put_notice(:throttled, "x<script>")
               |> RoomCodes.take_notice()

      assert {_, %{message: "no room with that code", code: ""}} =
               %Server{} |> RoomCodes.put_notice(:length, "AB") |> RoomCodes.take_notice()
    end

    test "no notice means no session write; an unexpected value shows nothing" do
      assert {%Server{} = server, nil} = RoomCodes.take_notice(%Server{})
      assert Server.get_session_ops(server) == %{}

      server = %Server{session: %{"room_code_notice" => "<b>hi</b>"}}
      assert {server, nil} = RoomCodes.take_notice(server)
      assert Server.get_session_ops(server) == %{"room_code_notice" => :delete}
    end
  end
end
