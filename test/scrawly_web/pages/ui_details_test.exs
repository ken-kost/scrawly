defmodule ScrawlyWeb.Pages.UiDetailsTest do
  @moduledoc """
  QA batch 4's small client and UI fixes: the lobby counts, the past games
  place, recovery-code copy feedback, logging in where you are, dead HomePage
  code, a chat throttle stamp from another document, the drawer's avatar, and
  the CSS rules that keep long words and narrow screens from widening pages.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.JsCallTrace, only: [js_execs: 1]

  alias Hologram.Component
  alias Hologram.Template.Renderer
  alias Scrawly.Games
  alias ScrawlyWeb.Components.RecoveryCodePanel
  alias ScrawlyWeb.Layouts.AppLayout
  alias ScrawlyWeb.Pages.{GamePage, HomePage, PastGamesPage, ProfilePage}

  @moduletag :capture_log

  defp render(module, state) do
    {html, _registry, _server} =
      module.template().(state)
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  describe "HomePage" do
    test "the hero counts open rooms and the players waiting in them, not 'today N rooms'" do
      {component, _server} = HomePage.init(%{}, %Component{}, anon_server())

      rooms = [
        %{
          room_id: "a",
          name: "TEST a",
          code: "A",
          status: :lobby,
          max_players: 4,
          players: [%{}, %{}]
        },
        %{room_id: "b", name: "TEST b", code: "B", status: :lobby, max_players: 4, players: [%{}]}
      ]

      html = render(HomePage, %{component.state | rooms: rooms})
      assert html =~ "open rooms"
      assert html =~ "3 waiting to play"
      refute html =~ "today"
      refute html =~ "2 open"

      one = render(HomePage, %{component.state | rooms: [hd(rooms)]})
      assert one =~ "open room<"
    end

    test "the never-dispatched watch / home actions and the watch-mode command are gone" do
      for name <- [:watch_room, :home] do
        assert_raise FunctionClauseError, fn ->
          HomePage.action(name, %{room_id: "r"}, %Component{state: %{}})
        end
      end

      result =
        HomePage.command(:enter_watch_mode, %{room_id: Ecto.UUID.generate()}, anon_server())

      assert result.next_action.params.reason == :unknown_command
      refute Map.has_key?(result.session, "watch_mode")
    end
  end

  describe "recovery code copy feedback" do
    test "every owner flags the copy, and a new or closed code clears it" do
      for owner <- [HomePage, AppLayout, ProfilePage] do
        component = %Component{
          state: %{
            recovery_code: "AAAA-BBBB",
            recovery_code_saved: false,
            recovery_code_copied: false,
            pending_auth: nil
          }
        }

        copied = owner.action(:copy_recovery_code, %{}, component)
        assert copied.state.recovery_code_copied == true, inspect(owner)

        closed = owner.action(:close_recovery_code, %{}, copied)
        assert closed.state.recovery_code_copied == false, inspect(owner)
      end
    end

    test "the panel's copy button says so" do
      base = %{code: "AAAA-BBBB", saved: false}
      assert render(RecoveryCodePanel, Map.put(base, :copied, false)) =~ ">copy</button>"
      assert render(RecoveryCodePanel, Map.put(base, :copied, true)) =~ "copied ✓"
    end
  end

  test "logging in from the header reloads the page the user is on (not /)" do
    component = %Component{state: %{authenticated: false}}

    {result, scripts} =
      js_execs(fn -> AppLayout.action(:auth_success, %{username: "TESTx"}, component) end)

    assert result.next_page == nil
    assert Enum.any?(scripts, &(&1 =~ "window.location.reload()"))
    assert result.state.authenticated == true
  end

  describe "PastGamesPage" do
    test "the place column shows the player's place, ties sharing it" do
      host = create_user()
      a = create_user()
      b = create_user()
      {:ok, room} = Games.create_room(%{name: "TEST place", max_players: 4, creator_id: host.id})
      {:ok, game} = Games.create_game(room.id, 2)

      for {user, score} <- [{host, 100}, {a, 100}, {b, 40}] do
        {:ok, _} =
          Games.create_game_result(%{
            player_id: user.id,
            game_id: game.id,
            room_id: room.id,
            score: score,
            player_username: user.username
          })
      end

      places =
        for user <- [host, a, b] do
          [%{place: place}] = init_page(user).state.results
          place
        end

      assert places == ["1st of 3", "1st of 3", "3rd of 3"]

      html = render(PastGamesPage, init_page(b).state)
      assert html =~ "3rd of 3"
      assert html =~ ">place<"
      refute html =~ "—"
    end

    test "place_label/2 ordinals" do
      assert PastGamesPage.place_label(1, 1) == "1st of 1"
      assert PastGamesPage.place_label(2, 5) == "2nd of 5"
      assert PastGamesPage.place_label(3, 4) == "3rd of 4"
      assert PastGamesPage.place_label(4, 12) == "4th of 12"
      assert PastGamesPage.place_label(11, 13) == "11th of 13"
      assert PastGamesPage.place_label(12, 13) == "12th of 13"
      assert PastGamesPage.place_label(13, 13) == "13th of 13"
      assert PastGamesPage.place_label(21, 22) == "21st of 22"
      assert PastGamesPage.place_label(22, 22) == "22nd of 22"
    end

    defp init_page(user) do
      PastGamesPage.init(%{}, %Component{}, server_for(user))
    end
  end

  describe "GamePage" do
    test "a throttle stamp from another document's clock doesn't count" do
      now = System.monotonic_time(:millisecond)

      state = %{
        is_drawer: false,
        rate_limited: false,
        new_message: "TEST hello",
        # A Back/Forward restore after a reload: the old document's clock
        # was far ahead of this one.
        message_timestamps: [now + 600_000, now + 500_000, now + 400_000]
      }

      result =
        GamePage.action(:send_message, %{}, %Component{props: %{room_id: "r1"}, state: state})

      assert result.state.rate_limited == false
      assert result.next_command.name == :submit_guess
      assert [stamp] = result.state.message_timestamps
      assert stamp <= System.monotonic_time(:millisecond)
    end

    test "the canvas header shows the drawer's own avatar" do
      players = [
        %{id: "u1", username: "TESTdrawer", score: 0, avatar_id: "a-star", avatar_color: "7"},
        %{id: "u2", username: "TESTguesser", score: 0, avatar_id: "a-cat", avatar_color: "2"}
      ]

      view = %{
        seq: 2,
        status: :playing,
        players: players,
        watchers: [],
        game_id: "g1",
        current_round: 1,
        total_rounds: 2,
        current_drawer_id: "u1",
        correct_guessers: [],
        phase: :drawing
      }

      state = %{
        last_seq: 1,
        leaving?: false,
        current_user_id: "u2",
        players: players,
        is_creator: false,
        game_started: false,
        game_id: "",
        round: 0,
        phase: :idle,
        is_drawer: false,
        max_players: 4,
        total_rounds: 0,
        past_games: [],
        pending_private: nil,
        tick_gen: 1,
        last_tick_at: nil,
        round_duration: 60,
        choice_duration: 15
      }

      result =
        GamePage.action(:room_delta, view, %Component{props: %{room_id: "r1"}, state: state})

      assert result.state.current_drawer == %{
               id: "u1",
               username: "TESTdrawer",
               avatar_id: "a-star",
               avatar_color: "7"
             }

      template = File.read!("lib/scrawly_web/pages/game_page.ex")
      assert template =~ ~s(<Avatar avatar_id={@current_drawer.avatar_id})
    end
  end

  describe "CSS" do
    setup do
      %{css: File.read!("assets/css/app.css")}
    end

    defp rule(css, selector) do
      [_, body] = Regex.run(~r/(?:^|\n)#{Regex.escape(selector)} \{([^}]*)\}/, css)
      body
    end

    test "chat lines wrap anywhere and grid columns may shrink (QA B3)", %{css: css} do
      assert rule(css, ".msg") =~ "overflow-wrap: anywhere"
      assert rule(css, ".msg") =~ "min-width: 0"
      assert css =~ ".game-layout > *,\n.lobby-grid > *,\n.home-grid > * { min-width: 0; }"
    end

    test "system lines keep the usernames' case; username chips too", %{css: css} do
      refute rule(css, ".msg.system") =~ "text-transform"
      assert css =~ ".chip-name { text-transform: none; }"
    end

    test "the canvas shell is sized to the canvas and toolbar", %{css: css} do
      assert rule(css, ".canvas-shell") =~ "align-self: start"
    end

    test "narrow screens: the header keeps the account chip's avatar only (QA P1)", %{css: css} do
      assert css =~ ".user-chip .user-chip-name { display: none; }"
      assert css =~ "@media (max-width: 370px)"
    end
  end
end
