defmodule Scrawly.Games.RoomServerBroadcastTest do
  @moduledoc """
  What a live room pushes (`RoomServer.Broadcasts`), seen the way the SSE
  connections see it: on Hologram.PubSub topics.

    * Every `{:room, id}` broadcast carries a seq exactly one higher than the
      previous one, whoever produced it (chat, strokes, deltas), and a
      restarted room counts on from above what it sent before.
    * The drawer's choices and word go only to the drawer's
      `{:room_player, room_id, user_id}` channel, AFTER the public delta of the
      same transition, and never appear on `{:room}`.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.RoomServer

  @moduletag :capture_log

  @word "zzyzx"
  @choices [@word, "TESTquokka", "TESTfjord"]

  setup do
    creator = create_user()
    player = create_user()
    room = start_room(creator)
    %{room: room, creator: creator, player: player}
  end

  defp subscribe(channel),
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))

  defp subscribe_all(%{room: room, creator: creator, player: player}) do
    subscribe({:room, room.id})
    subscribe({:room_player, room.id, creator.id})
    subscribe({:room_player, room.id, player.id})
  end

  # Every broadcast received so far (waiting `ms` for stragglers), in order.
  defp drain(ms \\ 50, acc \\ []) do
    receive do
      {:broadcast_action, channel, action, params, except} ->
        drain(ms, [{channel, action, params, except} | acc])
    after
      ms -> Enum.reverse(acc)
    end
  end

  defp public(messages), do: for({{:room, _}, _, _, _} = m <- messages, do: m)

  defp seqs(messages), do: for({_, _, %{seq: seq}, _} <- public(messages), do: seq)

  defp pid_of(room) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
    pid
  end

  defp join!(room, user) do
    {:ok, _} = RoomServer.join(room.id, %{id: user.id, username: user.username, score: 0})
  end

  defp start!(room, creator, entries \\ @choices) do
    {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: choices(entries)})
    started
  end

  describe "seq" do
    test "goes up by exactly one across chat, strokes and deltas", ctx do
      %{room: room, creator: creator, player: player} = ctx
      before = room_state!(room.id).seq
      subscribe({:room, room.id})

      join!(room, player)
      {:ok, :chat} = RoomServer.submit_message(room.id, player.id, "TEST hello")
      start!(room, creator)
      :ok = RoomServer.system_message(room.id, "TEST status")
      {:ok, _} = RoomServer.choose_word(room.id, creator.id, @word)

      stroke = %{id: "s-1", path: "M 1 1 L 2 2", color: "#000000", width: 2}
      :ok = RoomServer.append_drawing(room.id, creator.id, stroke)
      :ok = RoomServer.append_drawing(room.id, creator.id, %{stroke | id: "s-2"})
      :ok = RoomServer.undo_drawing(room.id, creator.id, "s-2")
      :ok = RoomServer.clear_drawing(room.id, creator.id)
      {:ok, {:correct, _}} = RoomServer.submit_message(room.id, player.id, @word)

      messages = drain()
      actions = messages |> public() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

      assert actions ==
               Enum.sort([
                 :chat_appended,
                 :room_delta,
                 :stroke_completed,
                 :drawing_undone,
                 :drawing_cleared
               ])

      seqs = seqs(messages)
      assert length(seqs) == length(public(messages))
      assert seqs == Enum.to_list((before + 1)..(before + length(seqs)))
      assert List.last(seqs) == room_state!(room.id).seq

      # Nobody is excluded from a sequenced broadcast.
      assert Enum.all?(public(messages), fn {_, _, _, except} -> except == [] end)

      # A chat line's id is its seq.
      for {_, :chat_appended, %{message: msg, seq: seq}, _} <- messages, do: assert(msg.id == seq)
    end

    test "is higher after a RoomServer restart than before it", %{room: room} do
      # A burst far faster than one broadcast per ms: a seed in ms could
      # restart below it.
      for n <- 1..200, do: :ok = RoomServer.system_message(room.id, "TEST #{n}")
      before = room_state!(room.id).seq

      kill_room!(room)
      {:ok, _pid} = RoomServer.ensure_started(room.id)
      restarted = room_state!(room.id).seq
      assert restarted > before

      subscribe({:room, room.id})
      :ok = RoomServer.system_message(room.id, "TEST after")
      assert [{_, :chat_appended, %{seq: seq}, _}] = drain()
      assert seq == restarted + 1
    end
  end

  describe "the drawer's private slice" do
    test "game start: the choices follow the delta, on the drawer's channel only", ctx do
      %{room: room, creator: creator, player: player} = ctx
      join!(room, player)
      subscribe_all(ctx)

      started = start!(room, creator)
      messages = drain()

      assert [
               {{:room, _}, :chat_appended, _, _},
               {{:room, _}, :room_delta, %{phase: :choosing, current_round: 1} = delta, _},
               {{:room_player, _, drawer_id}, :private_state, slice, []}
             ] = messages

      assert drawer_id == creator.id

      assert slice == %{
               game_id: started.game_id,
               round: 1,
               phase: :choosing,
               current_word: nil,
               word_choices: choices(@choices)
             }

      refute Map.has_key?(slice, :seq)
      refute Map.has_key?(delta, :word_choices)
      assert player.id != drawer_id
    end

    test "the choices' difficulties reach the drawer alone; the chosen one, everyone", ctx do
      %{room: room, creator: creator, player: player} = ctx
      join!(room, player)
      subscribe_all(ctx)

      start!(room, creator, [{@word, :easy}, {"TESTquokka", :medium}, {"TESTfjord", :hard}])
      choosing = drain()

      {to_drawer, to_others} =
        Enum.split_with(
          choosing,
          &match?({{:room_player, _, id}, _, _, _} when id == creator.id, &1)
        )

      assert [{_, :private_state, %{word_choices: drawer_choices}, _}] = to_drawer
      assert Enum.map(drawer_choices, & &1.difficulty) == [:easy, :medium, :hard]

      # Nothing on {:room} or the other player's channel names a difficulty
      # while the drawer chooses.
      assert to_others != []
      refute Enum.any?(to_others, &match?({{:room_player, _, _}, _, _, _}, &1))

      for {_, _, params, _} <- to_others do
        assert Map.get(params, :word_difficulty) == nil
        refute inspect(params, limit: :infinity) =~ ~r/:easy|:medium|:hard/
      end

      # Nor does the other player's own view of the room.
      {:ok, view} = RoomServer.get_view(room.id, player.id)
      assert view.word_choices == [] and view.word_difficulty == nil
      refute inspect(view, limit: :infinity) =~ ~r/:easy|:medium|:hard/

      # Once the drawer picks the hard one, its difficulty goes to everyone.
      {:ok, _} = RoomServer.choose_word(room.id, creator.id, "TESTfjord")

      assert [%{word_difficulty: :hard}] =
               for({{:room, _}, :room_delta, delta, _} <- drain(), do: delta)

      assert {:ok, %{word_difficulty: :hard}} = RoomServer.get_view(room.id, player.id)
    end

    test "commit: the word follows the :drawing delta, from choose_word and from the auto-pick",
         ctx do
      %{room: room, creator: creator, player: player} = ctx
      join!(room, player)

      for commit <- [:choose, :auto_pick] do
        started = start!(room, creator)
        subscribe_all(ctx)

        case commit do
          :choose -> {:ok, _} = RoomServer.choose_word(room.id, creator.id, @word)
          :auto_pick -> send(pid_of(room), {:word_choice_timeout, started.game_id, 1})
        end

        # Handled (and broadcast) before :sys.get_state/1 returns.
        :sys.get_state(pid_of(room))

        messages = drain()

        assert {{:room_player, _, drawer_id}, :private_state, slice, []} = List.last(messages)
        assert drawer_id == creator.id
        assert %{round: 1, phase: :drawing, word_choices: []} = slice
        assert slice.current_word in @choices

        delta_at =
          Enum.find_index(messages, &match?({{:room, _}, :room_delta, %{phase: :drawing}, _}, &1))

        assert delta_at == length(messages) - 2
        assert Enum.count(messages, &match?({_, :private_state, _, _}, &1)) == 1

        # Back to the lobby for the next pass.

        Phoenix.PubSub.unsubscribe(
          Hologram.PubSub,
          Hologram.Realtime.channel_topic({:room, room.id})
        )

        for user <- [creator, player] do
          Phoenix.PubSub.unsubscribe(
            Hologram.PubSub,
            Hologram.Realtime.channel_topic({:room_player, room.id, user.id})
          )
        end

        {:ok, _} = RoomServer.end_game(room.id)
        send(pid_of(room), :return_to_lobby)
        join!(room, creator)
        join!(room, player)
        drain()
      end
    end

    test "next round: the new drawer's choices follow the round's delta", ctx do
      %{room: room, creator: creator, player: player} = ctx
      seed_test_words()
      join!(room, player)
      start!(room, creator)
      {:ok, _} = RoomServer.choose_word(room.id, creator.id, @word)
      assert expire_round!(room).phase == :round_end
      subscribe_all(ctx)

      send(pid_of(room), :auto_advance_round)
      :sys.get_state(pid_of(room))
      messages = drain()

      assert {{:room_player, _, drawer_id}, :private_state, slice, []} = List.last(messages)
      assert drawer_id == player.id
      assert %{round: 2, phase: :choosing, current_word: nil, word_choices: [_ | _]} = slice

      assert {{:room, _}, :room_delta, %{current_round: 2, current_drawer_id: ^drawer_id}, _} =
               Enum.at(messages, -2)
    end

    test "the word and the choices never appear on {:room}", ctx do
      %{room: room, creator: creator, player: player} = ctx
      join!(room, player)
      subscribe({:room, room.id})

      start!(room, creator)
      {:ok, _} = RoomServer.choose_word(room.id, creator.id, @word)

      :ok =
        RoomServer.append_drawing(room.id, creator.id, %{
          id: "s-1",
          path: "M 1 1",
          color: "#000000",
          width: 2
        })

      {:ok, :chat} = RoomServer.submit_message(room.id, player.id, "TEST almost")
      {:ok, {:correct, _}} = RoomServer.submit_message(room.id, player.id, @word)

      messages = drain()
      assert length(messages) > 5

      for {channel, action, params, _} <- messages do
        assert {:room, _} = channel
        refute Map.has_key?(params, :current_word)
        refute Map.has_key?(params, :word_choices)

        # Only the round-end delta reveals the word, to everyone.
        unless action == :room_delta and params.phase == :round_end do
          dumped = inspect(params, limit: :infinity, printable_limit: :infinity)
          for word <- @choices, do: refute(dumped =~ word, "#{action} leaked #{word}")
        end
      end
    end
  end

  describe "the code" do
    test "sends no sequenced broadcast with *_except and never keys one on {:user, _}" do
      sources =
        for path <- Path.wildcard("lib/**/*.{ex,exs}"), do: {path, File.read!(path)}

      for {path, source} <- sources do
        refute source =~ ~r/(put_broadcast_except|broadcast_action_except)/, path
        refute source =~ ~r/\{:user,/, path
      end
    end

    test "has no poll left" do
      for path <- Path.wildcard("lib/**/*.{ex,exs,mjs}") do
        refute File.read!(path) =~
                 ~r/poll_room|room_refreshed|enrich_state|poll_and_enrich|handle_game_state_changes|sync_drawing_path/,
               path
      end
    end
  end
end
