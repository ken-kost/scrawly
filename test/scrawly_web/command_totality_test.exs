defmodule ScrawlyWeb.CommandTotalityTest do
  @moduledoc """
  QA B1: a malformed or unknown Hologram command must never raise. A raise was
  an HTTP 500 whose crash report printed the whole server struct (the signed
  session cookie, the CSRF token and the session's JWT).

  This walks every command name of every page, layout and component (read
  from their source, so new commands are covered automatically) plus unknown
  names, with `%{}`, non-map params and maps full of wrong types (also with a
  live room's id), as an anonymous visitor, a registered user and a guest.
  Every call must return a `%Hologram.Server{}`.
  """
  use Scrawly.DataCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Scrawly.RoomTestHelpers, only: [create_user: 0, start_room: 1]
  import Scrawly.SessionTestHelpers

  alias Hologram.Server
  alias Scrawly.Accounts
  alias ScrawlyWeb.Layouts.AppLayout

  alias ScrawlyWeb.Pages.{
    GamePage,
    GameScorePage,
    HomePage,
    PastGamesPage,
    ProfilePage,
    RoomLinkPage
  }

  alias ScrawlyWeb.Components.{
    Avatar,
    AvatarDefs,
    ChatBox,
    DrawingCanvas,
    GameDemo,
    RecoveryCodePanel,
    RoomList,
    RoomSettingsForm,
    ScoreBoard
  }

  @modules [
    AppLayout,
    HomePage,
    GamePage,
    GameScorePage,
    ProfilePage,
    PastGamesPage,
    RoomLinkPage,
    Avatar,
    AvatarDefs,
    ChatBox,
    DrawingCanvas,
    GameDemo,
    RecoveryCodePanel,
    RoomList,
    RoomSettingsForm,
    ScoreBoard
  ]

  @param_keys ~w(room_id email password password_confirmation current_password recovery_code
                 username avatar_id avatar_color dark_mode accent resync resubscribe word text
                 stroke_id path color width op_epoch op_seq gen message name max_players
                 answer_kind word_source prompt round_duration round_multiplier ai_tone
                 code settings)a

  @wrong_values [123, [1], %{a: 1}, nil, :atom, -1.5, {1, 2}, String.duplicate("é", 3000)]

  # Command names a module handles, from its source: `def command(:name`,
  # GamePage's `defp room_command(:name` and `when name in [:a, :b]` guards.
  defp command_names(module) do
    source = module.module_info(:compile)[:source] |> to_string() |> File.read!()

    direct =
      Regex.scan(~r/def(?:p room_command| command)\(\s*:(\w+)/, source, capture: :all_but_first)

    guarded =
      ~r/def command\(name, params, server\) when name in \[([^\]]+)\]/
      |> Regex.scan(source, capture: :all_but_first)
      |> Enum.flat_map(fn [list] -> Regex.scan(~r/:(\w+)/, list, capture: :all_but_first) end)

    (direct ++ guarded) |> List.flatten() |> Enum.uniq() |> Enum.map(&String.to_atom/1)
  end

  defp garbage_params(room_id) do
    wrong =
      @param_keys
      |> Enum.with_index()
      |> Map.new(fn {key, i} -> {key, Enum.at(@wrong_values, rem(i, length(@wrong_values)))} end)

    [
      %{},
      nil,
      "params",
      [1, 2],
      123,
      wrong,
      Map.put(wrong, :room_id, room_id),
      Map.new(wrong, fn {key, value} -> {Atom.to_string(key), value} end)
    ]
  end

  setup do
    creator = create_user()
    room = start_room(creator)

    # :create_room with no values creates a room (an empty name is the
    # user's room), so the walk starts rooms too: stop them all (no other
    # test runs alongside this one).
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Scrawly.RoomSupervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(Scrawly.RoomSupervisor, pid)
    end)

    {_email, user} = register!()
    guest = Accounts.register_as_guest!()

    servers = %{
      anonymous: %Server{session: %{}, session_id: "anon-walk"},
      registered: signed_in_server(user),
      guest: signed_in_server(guest)
    }

    %{room: room, servers: servers}
  end

  defp register! do
    email = "walk-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_with_password(email, "password123")
    {email, user}
  end

  test "every module's command names were found" do
    assert :login in command_names(AppLayout)
    assert :sign_out in command_names(AppLayout)
    assert :create_room in command_names(HomePage)
    assert :join_by_code in command_names(HomePage)
    assert command_names(RoomLinkPage) == []
    assert :complete_stroke in command_names(GamePage)
    assert :update_room_settings in command_names(GamePage)
    assert :refresh_socket_token in command_names(GamePage)
    assert :leave_room in command_names(GameScorePage)
    assert :save_password in command_names(ProfilePage)
    assert command_names(PastGamesPage) == [:drop_stale_subscriptions]
    assert :drop_stale_subscriptions in command_names(ProfilePage)
    assert :resync_countdown in command_names(GameScorePage)
  end

  test "no command of any page, layout or component raises on malformed params", ctx do
    tokens = for {_kind, server} <- ctx.servers, t = server.session["user_token"], do: t

    {{failures, calls}, log} =
      with_log(fn ->
        for module <- @modules,
            name <- command_names(module) ++ [:definitely_not_a_command, "string_name", 42],
            params <- garbage_params(ctx.room.id),
            {kind, server} <- ctx.servers,
            reduce: {[], 0} do
          {failures, calls} ->
            failure =
              try do
                case module.command(name, params, server) do
                  %Server{} -> nil
                  other -> {module, name, kind, params, {:returned, other}}
                end
              rescue
                error -> {module, name, kind, params, Exception.format_banner(:error, error)}
              end

            {if(failure, do: [failure | failures], else: failures), calls + 1}
        end
      end)

    assert calls > 1_000
    assert failures == [], failures |> Enum.take(5) |> inspect(pretty: true, limit: 8)

    for token <- tokens, do: refute(log =~ token)
  end

  test "unknown names and malformed params are denied with :command_denied", ctx do
    server = ctx.servers.registered

    for {module, name, params} <- [
          {GamePage, :definitely_not_a_command, %{}},
          {GamePage, :join_room, %{}},
          {GamePage, :choose_word, %{room_id: ctx.room.id}},
          {GamePage, :update_room_settings, %{room_id: ctx.room.id}},
          {GamePage, :update_room_settings, %{room_id: ctx.room.id, settings: "phrases"}},
          {GameScorePage, :leave_room, %{room_id: "not-a-uuid"}},
          {AppLayout, :save_accent, %{accent: "chartreuse"}},
          {AppLayout, :save_theme, %{dark_mode: "yes"}},
          {HomePage, :enter_watch_mode, %{room_id: 1}},
          {ProfilePage, :save_password, %{current_password: 1}},
          {ProfilePage, :save_profile, %{}},
          {Avatar, :anything, %{}}
        ] do
      result = module.command(name, params, server)
      assert result.next_action.name == :command_denied, "#{inspect(module)} #{inspect(name)}"
      assert result.next_action.params.reason in [:invalid_params, :unknown_command]
    end
  end
end
