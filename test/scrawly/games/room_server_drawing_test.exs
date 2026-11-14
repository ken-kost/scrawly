defmodule Scrawly.Games.RoomServerDrawingTest do
  @moduledoc """
  Only the current drawer may change the canvas, only while `:drawing`, and
  only with strokes that pass `StrokeRules`. Drives `handle_call/3` directly on
  hand-built room states.
  """
  use ExUnit.Case, async: true

  alias Scrawly.Games.{RoomServer, StrokeRules}

  @drawer "drawer-id"
  @player "player-id"
  @watcher "watcher-id"
  @stroke %{path: "M 1 2 L 3 4", color: "#d63838", width: 5}

  defp room(attrs \\ []) do
    struct!(
      %RoomServer{
        room_id: "TEST-room-#{System.unique_integer([:positive])}",
        status: :playing,
        creator_id: @drawer,
        game_id: "TEST-game",
        phase: :drawing,
        current_round: 1,
        current_drawer_id: @drawer,
        current_word: "zzyzx",
        players: [%{id: @drawer, username: "D"}, %{id: @player, username: "P"}],
        watchers: [%{id: @watcher, username: "W"}],
        drawing_strokes: []
      },
      attrs
    )
  end

  defp call(state, msg) do
    {:reply, reply, new_state} = RoomServer.handle_call(msg, {self(), make_ref()}, state)
    {reply, new_state}
  end

  defp assert_unchanged(reply_state, state), do: assert(reply_state == state)

  describe "authorize/3 :draw" do
    test "allows the current drawer while :drawing" do
      assert RoomServer.authorize(room(), @drawer, :draw) == :ok
    end

    test "rejects anyone else" do
      for actor <- [@player, @watcher, "stranger", nil, 123] do
        assert RoomServer.authorize(room(), actor, :draw) == {:error, :not_drawer}
      end
    end

    test "rejects a nil actor when there is no drawer" do
      assert RoomServer.authorize(room(current_drawer_id: nil), nil, :draw) ==
               {:error, :not_drawer}
    end

    test "rejects the drawer outside :drawing" do
      for phase <- [:idle, :choosing, :round_end] do
        assert RoomServer.authorize(room(phase: phase), @drawer, :draw) == {:error, :wrong_phase}
      end
    end
  end

  describe "append_drawing" do
    test "stores only path, color and width for the drawer" do
      state = room()
      extra = Map.merge(@stroke, %{stroke_id: "s-1", user_id: @player, evil: "x"})

      assert {:ok, new_state} = call(state, {:append_drawing, @drawer, extra})
      assert new_state.drawing_strokes == [@stroke]
      assert new_state.version == state.version + 1
    end

    test "denies non-drawers and the wrong phase without changing state" do
      state = room(drawing_strokes: [@stroke])

      for actor <- [@player, @watcher, nil] do
        {reply, new_state} = call(state, {:append_drawing, actor, @stroke})
        assert reply == {:error, :not_drawer}
        assert_unchanged(new_state, state)
      end

      for phase <- [:choosing, :round_end, :idle] do
        state = room(phase: phase)
        {reply, new_state} = call(state, {:append_drawing, @drawer, @stroke})
        assert reply == {:error, :wrong_phase}
        assert_unchanged(new_state, state)
      end
    end

    test "rejects invalid strokes and returns the stored canvas" do
      state = room(drawing_strokes: [@stroke])

      for bad <- [
            %{@stroke | path: 123},
            %{@stroke | path: "M 1 2 <script>"},
            %{@stroke | path: String.duplicate("1", 65_537)},
            %{@stroke | color: "red"},
            %{@stroke | color: "#fff"},
            %{@stroke | width: 0},
            %{@stroke | width: 41},
            %{@stroke | width: "5"},
            Map.delete(@stroke, :color),
            "M 1 2 L 3 4"
          ] do
        {reply, new_state} = call(state, {:append_drawing, @drawer, bad})
        assert reply == {:error, :invalid_stroke, [@stroke]}, inspect(bad)
        assert_unchanged(new_state, state)
      end
    end

    test "rejects stroke 501" do
      full = List.duplicate(@stroke, StrokeRules.max_strokes())
      state = room(drawing_strokes: full)

      {reply, new_state} = call(state, {:append_drawing, @drawer, @stroke})
      assert reply == {:error, :stroke_limit, full}
      assert_unchanged(new_state, state)

      assert {:ok, _} =
               call(room(drawing_strokes: tl(full)), {:append_drawing, @drawer, @stroke})
    end

    test "rejects a stroke that would push the canvas over the byte budget" do
      big = %{@stroke | path: String.duplicate("1", 60_000)}
      # 33 * 60_000 = 1_980_000 bytes stored; one more 60 KB stroke is over 2 MB.
      strokes = List.duplicate(big, 33)
      state = room(drawing_strokes: strokes)

      {reply, new_state} = call(state, {:append_drawing, @drawer, big})
      assert reply == {:error, :stroke_limit, strokes}
      assert_unchanged(new_state, state)

      assert {:ok, _} = call(state, {:append_drawing, @drawer, @stroke})
    end
  end

  describe "clear_drawing and undo_drawing" do
    test "the drawer can clear and undo" do
      other = %{@stroke | color: "#000000"}
      state = room(drawing_strokes: [@stroke, other])

      assert {{:ok, [@stroke]}, undone} = call(state, {:undo_drawing, @drawer})
      assert undone.drawing_strokes == [@stroke]

      assert {:ok, cleared} = call(state, {:clear_drawing, @drawer})
      assert cleared.drawing_strokes == []

      assert {{:ok, []}, _} = call(room(), {:undo_drawing, @drawer})
    end

    test "anyone else, or the wrong phase, changes nothing" do
      state = room(drawing_strokes: [@stroke])

      for actor <- [@player, @watcher, nil], msg <- [:clear_drawing, :undo_drawing] do
        {reply, new_state} = call(state, {msg, actor})
        assert reply == {:error, :not_drawer}
        assert_unchanged(new_state, state)
      end

      state = room(phase: :round_end, drawing_strokes: [@stroke])

      for msg <- [:clear_drawing, :undo_drawing] do
        {reply, new_state} = call(state, {msg, @drawer})
        assert reply == {:error, :wrong_phase}
        assert_unchanged(new_state, state)
      end
    end
  end

  describe "member? and drawing_allowed?" do
    test "member? covers players and watchers only" do
      state = room()

      for id <- [@drawer, @player, @watcher] do
        assert {true, ^state} = call(state, {:member?, id})
      end

      for id <- ["stranger", nil] do
        assert {false, ^state} = call(state, {:member?, id})
      end
    end

    test "drawing_allowed? applies the :draw rule" do
      assert {true, _} = call(room(), {:drawing_allowed?, @drawer})
      assert {false, _} = call(room(), {:drawing_allowed?, @player})
      assert {false, _} = call(room(), {:drawing_allowed?, nil})
      assert {false, _} = call(room(phase: :choosing), {:drawing_allowed?, @drawer})
    end

    test "a room that is not running is never joinable or drawable" do
      missing = "TEST-missing-#{System.unique_integer([:positive])}"

      refute RoomServer.member?(missing, @drawer)
      refute RoomServer.drawing_allowed?(missing, @drawer)
      assert RoomServer.append_drawing(missing, @drawer, @stroke) == {:error, :not_found}
      assert RoomServer.clear_drawing(missing, @drawer) == {:error, :not_found}
      assert RoomServer.undo_drawing(missing, @drawer) == {:error, :not_found}
    end
  end
end
