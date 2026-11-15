defmodule Scrawly.Games.StrokeLimitsTest do
  @moduledoc """
  QA G14: what the canvas may cost the room and everyone in it.

    * Undo publishes only the undone stroke's id (`:drawing_undone`
      `%{stroke_id, seq}`), never the canvas, and the room call returns
      `:ok` instead of copying the canvas out.
    * The drawer gets 40 stroke ops (commit, undo, clear) per 5 s; past
      that the room answers `{:error, :rate_limited}` and the command sends
      no reply, so the drawer's op queue resends the op after its retry
      delay instead of losing it.
    * A round's replay (`round_results` strokes, saved in the Game's JSONB
      and rendered by the score page) keeps at most
      `StrokeRules.max_replay_strokes/0` strokes and
      `StrokeRules.max_replay_bytes/0` path bytes, in drawing order, without
      stroke ids; a cut replay is flagged. The score page applies the same
      cap to rows saved before it.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.{RoomServer, StrokeRules}
  alias ScrawlyWeb.Pages.{GamePage, GameScorePage}

  @moduletag :capture_log

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp stroke(n, path \\ "M 1 1 L 2 2"),
    do: %{id: "s-#{n}", path: path, color: "#000000", width: 2}

  setup do
    creator = create_user()
    player = create_user()
    room = start_room(creator)
    {:ok, _} = RoomServer.join(room.id, %{id: player.id, username: player.username, score: 0})
    start_drawing!(room, creator)
    %{room: room, creator: creator, player: player}
  end

  describe "undo" do
    test "publishes only the undone stroke's id and returns :ok", ctx do
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(1))
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(2))

      room_id = ctx.room.id
      Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room_id}))

      assert RoomServer.undo_drawing(room_id, ctx.creator.id, "s-1") == :ok

      assert_receive {:broadcast_action, {:room, ^room_id}, :drawing_undone, params, []}
      assert Map.delete(params, :seq) == %{stroke_id: "s-1"}
      assert room_state!(room_id).drawing_strokes == [stroke(2)]
    end

    test "an unknown id publishes nothing", ctx do
      room_id = ctx.room.id
      Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic({:room, room_id}))

      assert RoomServer.undo_drawing(room_id, ctx.creator.id, "s-unknown") == :duplicate
      refute_receive {:broadcast_action, _, _, _, _}, 50
    end
  end

  describe "stroke op rate limit" do
    test "40 ops per 5 s for the drawer; the 41st is refused and costs nothing", ctx do
      assert StrokeRules.op_rate_limit() == {40, 5_000}

      for n <- 1..38, do: :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(n))
      :ok = RoomServer.undo_drawing(ctx.room.id, ctx.creator.id, "s-38")
      :ok = RoomServer.clear_drawing(ctx.room.id, ctx.creator.id)

      seq = room_state!(ctx.room.id).seq

      assert RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(41)) ==
               {:error, :rate_limited}

      assert RoomServer.undo_drawing(ctx.room.id, ctx.creator.id, "s-1") ==
               {:error, :rate_limited}

      assert RoomServer.clear_drawing(ctx.room.id, ctx.creator.id) == {:error, :rate_limited}
      assert room_state!(ctx.room.id).seq == seq
      assert room_state!(ctx.room.id).drawing_strokes == []

      # Refused ops don't count: once the window has passed, ops go through.
      :sys.replace_state(pid_of(ctx.room), fn state ->
        %{
          state
          | stroke_rate_limits:
              Map.new(state.stroke_rate_limits, fn {k, ts} -> {k, Enum.map(ts, &(&1 - 5_000))} end)
        }
      end)

      assert :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(42))
    end

    test "other players' refused attempts don't spend the drawer's budget", ctx do
      for _ <- 1..50 do
        assert {:error, :not_drawer} =
                 RoomServer.append_drawing(ctx.room.id, ctx.player.id, stroke(1))
      end

      assert :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(1))
    end

    test "a rate-limited op gets no reply, so the drawer's queue resends it later", ctx do
      server = %{server_for(ctx.creator) | instance_id: "i-1"}

      for n <- 1..40,
          do: :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(n))

      base = %{room_id: ctx.room.id, op_epoch: "e", op_seq: 41}

      commit =
        GamePage.command(
          :complete_stroke,
          Map.merge(base, %{stroke_id: "s-41", path: "M 1 1", color: "#000000", width: 2}),
          server
        )

      undo = GamePage.command(:undo_drawing_cmd, Map.put(base, :stroke_id, "s-1"), server)
      clear = GamePage.command(:clear_drawing_cmd, base, server)

      for result <- [commit, undo, clear] do
        assert result.next_action == nil
        assert result.broadcasts == []
      end
    end
  end

  describe "the round replay" do
    test "keeps the first strokes up to the stroke and byte caps, without ids", ctx do
      max_strokes = StrokeRules.max_replay_strokes()
      max_bytes = StrokeRules.max_replay_bytes()
      assert {max_strokes, max_bytes} == {300, 65_536}

      many = for n <- 1..(max_strokes + 100), do: stroke(n)
      :sys.replace_state(pid_of(ctx.room), &%{&1 | drawing_strokes: many})
      expire_round!(ctx.room)

      [result] = :sys.get_state(pid_of(ctx.room)).round_results
      assert length(result.drawing_strokes) == max_strokes
      assert hd(result.drawing_strokes) == %{path: "M 1 1 L 2 2", color: "#000000", width: 2}
      assert result.drawing_truncated == true
    end

    test "stops at the byte cap", ctx do
      big = String.duplicate("1", 7_000)
      strokes = for n <- 1..20, do: stroke(n, "M " <> big)
      :sys.replace_state(pid_of(ctx.room), &%{&1 | drawing_strokes: strokes})
      expire_round!(ctx.room)

      [result] = :sys.get_state(pid_of(ctx.room)).round_results
      bytes = Enum.reduce(result.drawing_strokes, 0, &(byte_size(&1.path) + &2))
      assert bytes <= StrokeRules.max_replay_bytes()
      assert length(result.drawing_strokes) == div(StrokeRules.max_replay_bytes(), 7_002)
      assert result.drawing_truncated == true
    end

    test "a round that fits is kept whole", ctx do
      :ok = RoomServer.append_drawing(ctx.room.id, ctx.creator.id, stroke(1))
      expire_round!(ctx.room)

      [result] = :sys.get_state(pid_of(ctx.room)).round_results
      assert result.drawing_strokes == [%{path: "M 1 1 L 2 2", color: "#000000", width: 2}]
      assert result.drawing_truncated == false
    end

    test "the score page caps a replay saved before the cap", ctx do
      game_id = room_state!(ctx.room.id).game_id

      strokes =
        for n <- 1..1_000,
            do: %{"id" => "s-#{n}", "path" => "M 1 1 L 2 2", "color" => "#000000", "width" => 2}

      {:ok, game} = Games.get_game_by_id(game_id)

      {:ok, _} =
        Games.save_round_details(game, [
          %{"round" => 1, "word" => "zzyzx", "drawer_name" => "x", "drawing_strokes" => strokes}
        ])

      {component, _server} =
        GameScorePage.init(%{game_id: game_id}, %Hologram.Component{}, server_for(ctx.creator))

      [round] = component.state.round_details
      assert length(round.drawing_strokes) == StrokeRules.max_replay_strokes()
      assert round.drawing_truncated == true

      # The page says the drawing was trimmed, and renders only what was kept.
      {html, _registry, _server} =
        GameScorePage.template().(Map.put(component.state, :game_id, game_id))
        |> Hologram.Template.Renderer.render_dom(
          %Hologram.Template.Renderer.Env{},
          %Hologram.Server{}
        )

      assert html =~ "drawing trimmed"

      assert length(String.split(html, "<path d=\"M 1 1 L 2 2\"")) - 1 ==
               StrokeRules.max_replay_strokes()
    end
  end
end
