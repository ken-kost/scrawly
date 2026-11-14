defmodule ScrawlyWeb.Components.DrawingCanvasTest do
  @moduledoc """
  Tests for drawing actions on GamePage including tool selection,
  multi-stroke state, undo, the canvas lifecycle (`:mounted`) and the round
  resets.
  """
  use ExUnit.Case, async: true

  alias ScrawlyWeb.Pages.GamePage

  defp drawing_component(overrides \\ %{}) do
    defaults = %{
      drawing_strokes: [],
      drawing?: false,
      draw_color: "#000000",
      draw_width: 2,
      draw_eraser: false,
      is_drawer: true,
      game_started: true,
      time_left: 60,
      room_id: "test-room",
      current_user_id: "test-user"
    }

    %Hologram.Component{state: Map.merge(defaults, overrides)}
  end

  @s1 %{id: "s-1", path: "M 1 2", color: "#000000", width: 2}
  @s2 %{id: "s-2", path: "M 3 4 L 5 6", color: "#d63838", width: 5}

  # The full page state of a viewer (user-1) in round 1 of game g1, :drawing.
  defp page_component(overrides) do
    players = [
      %{id: "user-1", username: "You", score: 0},
      %{id: "user-2", username: "D", score: 0}
    ]

    state = %{
      room_id: "r1",
      room_code: "ABCD",
      socket_token: "",
      channel_connected: false,
      current_user_id: "user-1",
      players: players,
      max_players: 4,
      watchers: [],
      past_games: [],
      chat_messages: [],
      correct_guessers: [],
      is_creator: false,
      can_start_game: false,
      leaving?: false,
      room_status: :playing,
      version: 4,
      game_id: "g1",
      game_started: true,
      round: 1,
      total_rounds: 2,
      phase: :drawing,
      time_left: 50,
      choice_time_left: 0,
      current_drawer: %{id: "user-2", username: "D"},
      current_word: nil,
      current_word_display: "_ _ _",
      word_length: 3,
      revealed_word: nil,
      word_choices: [],
      is_drawer: false,
      drawing?: false,
      drawing_strokes: [@s1, @s2]
    }

    %Hologram.Component{state: Map.merge(state, overrides)}
  end

  # A :room_refreshed reply for user-1 (strokes stripped, as Commands sends it).
  defp refreshed(overrides) do
    Map.merge(
      %{
        room_id: "r1",
        status: :playing,
        players: [
          %{id: "user-1", username: "You", score: 0},
          %{id: "user-2", username: "D", score: 0}
        ],
        max_players: 4,
        watchers: [],
        past_games: [],
        chat_messages: [],
        correct_guessers: [],
        version: 5,
        game_id: "g1",
        last_game_id: nil,
        current_round: 1,
        total_rounds: 2,
        current_drawer_id: "user-2",
        drawer_name: "D",
        phase: :drawing,
        time_left: 45,
        choice_time_left: 0,
        word_display: "_ _ _",
        word_length: 3,
        revealed_word: nil,
        current_word: nil,
        word_choices: [],
        is_drawer: false,
        drawing_strokes: []
      },
      overrides
    )
  end

  describe "canvas_pointer_down" do
    test "starts drawing for drawer" do
      comp = drawing_component()
      params = %{event: %{offset_x: 100, offset_y: 150}}

      result = GamePage.action(:canvas_pointer_down, params, comp)

      assert result.state.drawing? == true
    end

    test "does nothing for non-drawer" do
      comp = drawing_component(%{is_drawer: false})
      params = %{event: %{offset_x: 100, offset_y: 150}}

      result = GamePage.action(:canvas_pointer_down, params, comp)

      assert result.state.drawing? == false
    end

    test "does nothing when time is 0" do
      comp = drawing_component(%{time_left: 0})
      params = %{event: %{offset_x: 100, offset_y: 150}}

      result = GamePage.action(:canvas_pointer_down, params, comp)

      assert result.state.drawing? == false
    end
  end

  describe "canvas_pointer_move" do
    test "does not update Hologram state (drawing managed by JS)" do
      comp = drawing_component(%{drawing?: true})
      params = %{event: %{offset_x: 120, offset_y: 160}}

      result = GamePage.action(:canvas_pointer_move, params, comp)

      # Strokes unchanged — JS handles SVG directly
      assert result.state.drawing_strokes == []
    end

    test "does nothing when not drawing" do
      comp = drawing_component(%{drawing?: false})
      params = %{event: %{offset_x: 120, offset_y: 160}}

      result = GamePage.action(:canvas_pointer_move, params, comp)

      assert result.state.drawing_strokes == []
    end
  end

  describe "canvas_pointer_up" do
    test "stops drawing" do
      comp = drawing_component(%{drawing?: true})

      result = GamePage.action(:canvas_pointer_up, %{}, comp)

      assert result.state.drawing? == false
    end
  end

  describe "clear_canvas" do
    test "resets strokes to empty" do
      strokes = [%{id: "s-1", path: "M 100 150 L 120 160", color: "#000000", width: 2}]
      comp = drawing_component(%{drawing_strokes: strokes})

      result = GamePage.action(:clear_canvas, %{}, comp)

      assert result.state.drawing_strokes == []
    end
  end

  describe "stroke_completed" do
    test "appends completed stroke to non-drawer's strokes" do
      comp = drawing_component(%{is_drawer: false})
      params = %{stroke_id: "s1", path: "M 10 20 L 30 40", color: "#EF4444", width: 5}

      result = GamePage.action(:stroke_completed, params, comp)

      assert result.state.drawing_strokes == [
               %{id: "s1", path: "M 10 20 L 30 40", color: "#EF4444", width: 5}
             ]
    end

    test "ignores a stroke id the viewer already has" do
      comp = drawing_component(%{is_drawer: false, drawing_strokes: [@s1]})
      params = %{stroke_id: "s-1", path: "M 9 9", color: "#000000", width: 2}

      result = GamePage.action(:stroke_completed, params, comp)

      assert result.state.drawing_strokes == [@s1]
    end

    test "does nothing for drawer" do
      comp = drawing_component(%{is_drawer: true})
      params = %{stroke_id: "s1", path: "M 10 20", color: "#000000", width: 2}

      result = GamePage.action(:stroke_completed, params, comp)

      assert result.state.drawing_strokes == []
    end

    test "accumulates multiple strokes" do
      comp =
        drawing_component(%{
          is_drawer: false,
          drawing_strokes: [@s1]
        })

      params = %{stroke_id: "s2", path: "M 10 20", color: "#3B82F6", width: 10}

      result = GamePage.action(:stroke_completed, params, comp)

      assert length(result.state.drawing_strokes) == 2
    end
  end

  describe "drawing_cleared" do
    test "clears all strokes" do
      comp =
        drawing_component(%{
          drawing_strokes: [@s1]
        })

      result = GamePage.action(:drawing_cleared, %{}, comp)

      assert result.state.drawing_strokes == []
    end
  end

  describe ":mounted" do
    test "puts the follow-up init chose, exactly as init used to queue it" do
      comp = drawing_component()

      assert GamePage.action(:mounted, %{next: :poll_room, delay: 500}, comp).next_action ==
               %Hologram.Component.Action{name: :poll_room, delay: 500}

      for next <- [:do_join_as_watcher, :do_join_room] do
        result = GamePage.action(:mounted, %{next: next, delay: 0}, comp)
        assert result.next_action == %Hologram.Component.Action{name: next}
      end
    end

    test "changes no state, for the drawer or a viewer" do
      for is_drawer <- [true, false] do
        comp = drawing_component(%{is_drawer: is_drawer, drawing_strokes: [@s1]})
        result = GamePage.action(:mounted, %{next: :poll_room, delay: 500}, comp)
        assert result.state == comp.state
      end
    end
  end

  describe ":room_refreshed keeps the viewer's strokes" do
    test "replies carry drawing_strokes: [], with or without the channel" do
      for connected <- [false, true] do
        comp = page_component(%{channel_connected: connected})
        result = GamePage.action(:room_refreshed, refreshed(%{}), comp)
        assert result.state.drawing_strokes == [@s1, @s2]
      end
    end

    test "a longer non-empty list replaces it only once the channel is connected" do
      longer = [@s1, @s2, %{@s2 | id: "s-3"}]

      comp = page_component(%{channel_connected: true})
      result = GamePage.action(:room_refreshed, refreshed(%{drawing_strokes: longer}), comp)
      assert result.state.drawing_strokes == longer

      comp = page_component(%{channel_connected: true})
      result = GamePage.action(:room_refreshed, refreshed(%{drawing_strokes: [@s1]}), comp)
      assert result.state.drawing_strokes == [@s1, @s2]
    end
  end

  describe "round transitions stop the stroke in progress" do
    test "game start, new round and game end set drawing? to false" do
      lobby =
        page_component(%{
          game_started: false,
          game_id: nil,
          round: 0,
          phase: :idle,
          drawing?: true
        })

      started = GamePage.action(:room_refreshed, refreshed(%{phase: :choosing}), lobby)
      assert started.state.game_started == true
      assert started.state.drawing? == false

      in_round = page_component(%{is_drawer: true, drawing?: true})

      next_round =
        GamePage.action(
          :room_refreshed,
          refreshed(%{current_round: 2, phase: :choosing, current_drawer_id: "user-1"}),
          in_round
        )

      assert next_round.state.round == 2
      assert next_round.state.drawing? == false
      assert next_round.state.drawing_strokes == []

      ended =
        GamePage.action(
          :room_refreshed,
          refreshed(%{status: :lobby, game_id: nil, current_round: 0, phase: :idle}),
          in_round
        )

      assert ended.state.game_started == false
      assert ended.state.drawing? == false
      assert ended.state.drawing_strokes == []
    end

    test "leaving :drawing sets drawing? to false and keeps the strokes" do
      comp = page_component(%{is_drawer: true, drawing?: true})

      result =
        GamePage.action(
          :room_refreshed,
          refreshed(%{phase: :round_end, time_left: 0, revealed_word: "abc"}),
          comp
        )

      assert result.state.phase == :round_end
      assert result.state.drawing? == false
      assert result.state.drawing_strokes == [@s1, @s2]
    end

    test "a tick within :drawing leaves drawing? alone" do
      comp = page_component(%{is_drawer: true, drawing?: true})
      result = GamePage.action(:room_refreshed, refreshed(%{time_left: 30}), comp)

      assert result.state.drawing? == true
      assert result.state.time_left == 30
    end
  end

  describe "tool selection actions" do
    test "select_color updates draw_color and disables eraser" do
      comp = drawing_component(%{draw_eraser: true, draw_color: "#000000"})

      result = GamePage.action(:select_color, %{color: "#EF4444"}, comp)

      assert result.state.draw_color == "#EF4444"
      assert result.state.draw_eraser == false
    end

    test "select_width updates draw_width" do
      comp = drawing_component(%{draw_width: 2})

      result = GamePage.action(:select_width, %{width: 10}, comp)

      assert result.state.draw_width == 10
    end

    test "toggle_eraser enables eraser" do
      comp = drawing_component(%{draw_eraser: false})

      result = GamePage.action(:toggle_eraser, %{}, comp)

      assert result.state.draw_eraser == true
    end

    test "toggle_eraser disables eraser on second toggle" do
      comp = drawing_component(%{draw_eraser: true})

      result = GamePage.action(:toggle_eraser, %{}, comp)

      assert result.state.draw_eraser == false
    end
  end
end
