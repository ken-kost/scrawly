defmodule ScrawlyWeb.Pages.HomePageCreateRoomTest do
  @moduledoc """
  Creating a room from Home (create-room-form).

  `:create_room` takes the form's values (RoomSettingsForm, all strings). The
  defaults create a playable room; an empty name becomes "<username>'s
  room". Anything the server refuses replies `:create_room_failed` with the
  field to show it next to (or nil) and a message for the form, never an
  exception and never a bare `server`. Forged values are refused the same
  way; a forged answer kind is the default one instead, like a forged word
  source is the built-in list.

  The page side: the form stays open, "creating…", until the reply, and a
  failure keeps it open with its values.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers, only: [signed_in_server: 1]

  require Ash.Query

  alias Hologram.Component
  alias Hologram.Component.Action
  alias Scrawly.Accounts
  alias Scrawly.Accounts.User
  alias Scrawly.Games.{Room, RoomServer}
  alias ScrawlyWeb.Pages.HomePage
  alias ScrawlyWeb.RoomSettings

  @moduletag :capture_log

  # What the form sends when the user changed everything.
  @form %{
    name: "TEST forged",
    max_players: "6",
    answer_kind: "phrases",
    word_source: "ai",
    prompt: "ocean animals",
    round_duration: "120",
    round_multiplier: "3",
    ai_tone: "weird"
  }

  @generic "couldn't create the room, try again"

  defp rooms_by(user), do: Room |> Ash.Query.filter(creator_id == ^user.id) |> Ash.read!()

  defp created!(result) do
    assert %Action{name: :join_room_with_user, params: %{room_id: room_id}} = result.next_action
    on_exit(fn -> stop_room(room_id) end)
    room_id
  end

  defp failed(result) do
    assert %Action{name: :create_room_failed, params: %{field: field, message: message}} =
             result.next_action

    {field, message}
  end

  describe "command :create_room" do
    test "the form's defaults create a playable room and take its creator there" do
      user = create_user()

      room_id =
        HomePage.command(:create_room, RoomSettings.defaults(), server_for(user)) |> created!()

      assert [room] = rooms_by(user)
      assert room.id == room_id

      assert %{
               name: name,
               max_players: 8,
               answer_kind: :mixed,
               word_source: :local,
               prompt: nil,
               round_duration: 60,
               round_multiplier: 1,
               ai_tone: :fun,
               status: :lobby
             } = room

      assert name == user.username <> "'s room"

      assert {:ok, state} = RoomServer.get_state(room_id)
      assert Enum.map(state.players, & &1.id) == [user.id]
      assert {:ok, %{current_room_id: ^room_id}} = Accounts.get_user_by_id(user.id)
    end

    test "an empty, blank or missing name becomes \"<username>'s room\"" do
      user = create_user()

      for params <- [%{name: ""}, %{name: "   "}, %{name: nil}, %{}] do
        HomePage.command(:create_room, params, server_for(user)) |> created!()
      end

      names = user |> rooms_by() |> Enum.map(& &1.name) |> Enum.uniq()
      assert names == [user.username <> "'s room"]
    end

    test "the form's values create the room with parsed values" do
      user = create_user()

      room_id = HomePage.command(:create_room, @form, server_for(user)) |> created!()

      assert [room] = rooms_by(user)
      assert room.id == room_id

      assert %{
               name: "TEST forged",
               max_players: 6,
               answer_kind: :phrases,
               word_source: :ai,
               prompt: "ocean animals",
               round_duration: 120,
               round_multiplier: 3,
               ai_tone: :weird
             } = room
    end

    test "a refused room replies :create_room_failed for the form and creates nothing" do
      user = create_user()
      server = server_for(user)
      theme_missing = {:prompt, "type a theme, or pick everything"}

      cases = [
        {%{@form | name: String.duplicate("n", 41)},
         {:name, "use a name of at most 40 characters"}},
        # 40 characters, 280 bytes (the Room's byte cap is 160).
        {%{@form | name: String.duplicate("a" <> String.duplicate("\u0301", 3), 40)},
         {:name, "use a name of at most 40 characters"}},
        {%{@form | name: %{"x" => 1}}, {:name, "use a name of at most 40 characters"}},
        {%{@form | prompt: String.duplicate("p", 201)},
         {:prompt, "use a theme of at most 200 characters"}},
        {%{@form | prompt: ""}, theme_missing},
        {%{@form | prompt: "   "}, theme_missing},
        {%{@form | prompt: nil}, theme_missing},
        {Map.delete(@form, :prompt), theme_missing},
        {%{@form | max_players: "1"}, {:max_players, "pick 2 to 12 players"}},
        {%{@form | max_players: "13"}, {:max_players, "pick 2 to 12 players"}},
        {%{@form | max_players: "many"}, {:max_players, "pick 2 to 12 players"}},
        {%{@form | max_players: %{"x" => 1}}, {:max_players, "pick 2 to 12 players"}},
        {%{@form | round_duration: "1e3"}, {nil, @generic}},
        {%{@form | round_duration: "30"}, {nil, @generic}},
        {%{@form | round_multiplier: "0"}, {nil, @generic}},
        {%{@form | ai_tone: "nope"}, {nil, @generic}},
        {%{@form | ai_tone: "Elixir.Kernel"}, {nil, @generic}},
        {%{@form | ai_tone: 7}, {nil, @generic}}
      ]

      for {params, expected} <- cases do
        assert failed(HomePage.command(:create_room, params, server)) == expected,
               "#{inspect(params, limit: 3, printable_limit: 20)}"
      end

      assert rooms_by(user) == []
    end

    test "guests and visitors without an account are told, not given a room" do
      guest = Accounts.register_as_guest!()

      assert failed(
               HomePage.command(:create_room, %{name: "TEST guest"}, signed_in_server(guest))
             ) ==
               {nil, "register an account to create rooms"}

      assert failed(HomePage.command(:create_room, %{name: "TEST anon"}, anon_server())) ==
               {nil, "sign in to create a room"}

      assert rooms_by(guest) == []
    end

    test "an unexpected refusal gets the general message" do
      # A session user the database doesn't know: the room's creator_id
      # references users, so the insert fails.
      ghost = %User{id: Ecto.UUID.generate(), username: "TESTghost", is_guest: false}
      server = %Hologram.Server{stash: %{current_user_id: ghost.id, current_user: ghost}}

      assert failed(HomePage.command(:create_room, %{name: "TEST ghost room"}, server)) ==
               {nil, @generic}

      assert rooms_by(ghost) == []
    end

    test "a room its creator can't join is dissolved again, and the form told" do
      user = create_user()

      # The database refuses this user's join (inside the test's transaction,
      # so the trigger goes with it).
      Scrawly.Repo.query!("""
      CREATE FUNCTION test_refuse_join() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'TEST join refused'; END $$ LANGUAGE plpgsql
      """)

      Scrawly.Repo.query!("""
      CREATE TRIGGER test_refuse_join BEFORE UPDATE OF current_room_id ON users
      FOR EACH ROW WHEN (NEW.id = '#{user.id}') EXECUTE FUNCTION test_refuse_join()
      """)

      assert failed(HomePage.command(:create_room, %{name: "TEST unjoinable"}, server_for(user))) ==
               {nil, @generic}

      assert [%{status: :ended} = room] = rooms_by(user)
      assert {:error, :not_found} = RoomServer.get_state(room.id)
      refute room.id in Enum.map(RoomServer.list_lobby_rooms(), & &1.room_id)
    end

    test "every answer kind the form offers is kept" do
      user = create_user()

      for kind <- ["words", "phrases", "mixed"] do
        params = %{@form | name: "TEST kind #{kind}", answer_kind: kind}
        HomePage.command(:create_room, params, server_for(user)) |> created!()
      end

      kinds = user |> rooms_by() |> Map.new(&{&1.name, &1.answer_kind})

      assert kinds == %{
               "TEST kind words" => :words,
               "TEST kind phrases" => :phrases,
               "TEST kind mixed" => :mixed
             }
    end

    test "a forged answer kind creates a mixed room" do
      user = create_user()

      for {forged, i} <-
            Enum.with_index(["Words", "phrase", "1", "2", "Elixir.Kernel", 7, :phrase, %{}]) do
        params = %{@form | name: "TEST forged kind #{i}", answer_kind: forged}
        HomePage.command(:create_room, params, server_for(user)) |> created!()
      end

      rooms = rooms_by(user)
      assert length(rooms) == 8
      assert Enum.all?(rooms, &(&1.answer_kind == :mixed))
    end

    test "missing or nil values fall back to the Room's defaults; a built-in room keeps no theme" do
      user = create_user()

      for params <- [
            %{name: "TEST minimal"},
            %{@form | answer_kind: nil, ai_tone: nil, max_players: nil},
            %{@form | name: "TEST local", word_source: "local"}
          ] do
        HomePage.command(:create_room, params, server_for(user)) |> created!()
      end

      rooms = Map.new(rooms_by(user), &{&1.name, &1})

      assert %{
               max_players: 12,
               answer_kind: :mixed,
               word_source: :local,
               prompt: nil,
               round_duration: 60,
               round_multiplier: 1,
               ai_tone: :fun
             } = rooms["TEST minimal"]

      assert %{max_players: 12, answer_kind: :mixed, ai_tone: :fun, word_source: :ai} =
               rooms["TEST forged"]

      assert %{word_source: :local, prompt: nil, ai_tone: :fun} = rooms["TEST local"]
    end
  end

  describe "the page's form actions" do
    defp home(user) do
      server = %Hologram.Server{
        session: %{},
        stash: %{current_user_id: user.id, current_user: user}
      }

      {component, _server} = HomePage.init(%{}, %Component{}, server)
      component
    end

    defp open(component), do: HomePage.action(:show_create_room, %{}, component)

    defp registered,
      do: %User{id: Ecto.UUID.generate(), username: "TESTreg", is_guest: false}

    test "init: closed, nothing sent, the default name ready as the placeholder" do
      state = home(registered()).state

      assert %{
               show_create_room: false,
               creating_room?: false,
               create_room_errors: %{},
               create_room_form: 0,
               create_room_attempt: 0,
               default_room_name: "TESTreg's room"
             } = state

      refute Enum.any?(Map.keys(state), &String.starts_with?(Atom.to_string(&1), "new_"))
    end

    test "each opening is a fresh form (a new cid), without the last errors" do
      component = home(registered()) |> open()
      assert component.state.show_create_room
      assert component.state.create_room_form == 1

      failed =
        HomePage.action(:create_room_failed, %{field: :name, message: "TEST no"}, component)

      reopened = failed |> then(&HomePage.action(:hide_create_room, %{}, &1)) |> open()

      assert reopened.state.create_room_form == 2
      assert reopened.state.create_room_errors == %{}
      assert reopened.state.creating_room? == false
    end

    test "submitting sends the command, shows creating… and keeps the form open" do
      component = home(registered()) |> open()
      values = %{RoomSettings.defaults() | name: "TEST sent"}

      sent = HomePage.action(:create_room, %{values: values}, component)

      assert sent.state.show_create_room
      assert sent.state.creating_room?
      assert sent.next_command.name == :create_room
      assert sent.next_command.params == values

      assert sent.next_action == %Action{
               name: :create_room_timed_out,
               params: %{attempt: 1},
               delay: 20_000
             }

      # A second submit while the first runs sends nothing.
      again = HomePage.action(:create_room, %{values: values}, %{sent | next_command: nil})
      assert again.next_command == nil
    end

    test "a failure keeps the form open and shows the message where it belongs" do
      sent =
        home(registered())
        |> open()
        |> then(&HomePage.action(:create_room, %{values: RoomSettings.defaults()}, &1))

      named = HomePage.action(:create_room_failed, %{field: :name, message: "TEST long"}, sent)
      assert named.state.show_create_room
      assert named.state.creating_room? == false
      assert named.state.create_room_errors == %{name: "TEST long"}

      general = HomePage.action(:create_room_failed, %{field: nil, message: @generic}, sent)
      assert general.state.create_room_errors == %{form: @generic}

      # Sending again clears the old message.
      resent = HomePage.action(:create_room, %{values: RoomSettings.defaults()}, named)
      assert resent.state.create_room_errors == %{}
    end

    test "no reply in time gives the form back; a late timeout of an older request does nothing" do
      sent =
        home(registered())
        |> open()
        |> then(&HomePage.action(:create_room, %{values: RoomSettings.defaults()}, &1))

      timed_out = HomePage.action(:create_room_timed_out, %{attempt: 1}, sent)
      assert timed_out.state.creating_room? == false

      assert timed_out.state.create_room_errors == %{
               form: "no answer from the server, try again"
             }

      resent =
        sent
        |> then(&HomePage.action(:create_room_failed, %{field: nil, message: @generic}, &1))
        |> then(&HomePage.action(:create_room, %{values: RoomSettings.defaults()}, &1))

      assert HomePage.action(:create_room_timed_out, %{attempt: 1}, resent) == resent

      closed = HomePage.action(:hide_create_room, %{}, sent)
      assert HomePage.action(:create_room_timed_out, %{attempt: 1}, closed) == closed
    end

    test "success closes the form before going to the room (Back won't show it creating…)" do
      sent =
        home(registered())
        |> open()
        |> then(&HomePage.action(:create_room, %{values: RoomSettings.defaults()}, &1))

      room_id = Ecto.UUID.generate()
      joined = HomePage.action(:join_room_with_user, %{room_id: room_id}, sent)

      assert joined.state.show_create_room == false
      assert joined.state.creating_room? == false
      assert joined.next_page == {ScrawlyWeb.Pages.GamePage, [room_id: room_id]}
    end

    test "the page renders the form with its state as props" do
      component =
        home(registered())
        |> open()
        |> then(&HomePage.action(:create_room, %{values: RoomSettings.defaults()}, &1))
        |> then(&HomePage.action(:create_room_failed, %{field: :name, message: "TEST long"}, &1))

      {html, _registry, _server} =
        HomePage.template().(component.state)
        |> Hologram.Template.Renderer.render_dom(
          %Hologram.Template.Renderer.Env{},
          %Hologram.Server{}
        )

      assert html =~ ~s(id="create-room-1-name")
      assert html =~ ~s(placeholder="TESTreg&#39;s room")
      assert html =~ ~s(<div class="field-error">TEST long</div>)
    end
  end
end
