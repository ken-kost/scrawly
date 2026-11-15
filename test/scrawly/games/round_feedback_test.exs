defmodule Scrawly.Games.RoundFeedbackTest do
  @moduledoc """
  What a live room pushes for play feedback, seen the way the SSE
  connections see it (Hologram.PubSub topics):

    * a correct guess sends the answer to that player alone, on their own
      `{:room_player}` channel, after the delta that lists them as having
      guessed; nobody else receives it before the round ends;
    * the round-end delta carries the round summary (answer, every player's
      points, the drawer's points, who draws next), and no earlier
      broadcast does;
    * the `:round_end` pause lasts 5 seconds.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games.RoomServer
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @word "chicken crossing the road"

  setup do
    drawer = create_user()
    first = create_user()
    second = create_user()
    room = start_room(drawer)

    for user <- [first, second] do
      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
               :room_resynced
    end

    start_drawing!(room, drawer, @word)
    %{room: room, drawer: drawer, first: first, second: second}
  end

  defp subscribe(channel),
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))

  defp subscribe_all(%{room: room} = ctx) do
    subscribe({:room, room.id})

    for user <- [ctx.drawer, ctx.first, ctx.second],
        do: subscribe({:room_player, room.id, user.id})
  end

  defp drain(ms \\ 50, acc \\ []) do
    receive do
      {:broadcast_action, channel, action, params, _except} ->
        drain(ms, [{channel, action, params} | acc])
    after
      ms -> Enum.reverse(acc)
    end
  end

  defp dump(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp guess!(ctx, user, text) do
    GamePage.command(:submit_guess, %{room_id: ctx.room.id, text: text}, server_for(user))
  end

  defp for_channel(messages, channel), do: for({^channel, _, _} = m <- messages, do: m)

  describe "a correct guess" do
    test "sends the answer to the guesser alone, after the delta that lists them", ctx do
      %{room: room, first: first, second: second, drawer: drawer} = ctx
      subscribe_all(ctx)

      reply = guess!(ctx, first, "Chicken-crossing the road!")
      assert %{outcome: :correct, points: points} = reply.next_action.params
      # The reply carries the points, never the word.
      refute dump(reply) =~ "chicken"

      messages = drain()

      assert [{_, :private_state, slice}] =
               for_channel(messages, {:room_player, room.id, first.id})

      assert slice == %{
               game_id: room_state!(room.id).game_id,
               round: 1,
               phase: :drawing,
               current_word: @word,
               word_choices: [],
               guess_points: points
             }

      assert for_channel(messages, {:room_player, room.id, second.id}) == []
      assert for_channel(messages, {:room_player, room.id, drawer.id}) == []

      public = for_channel(messages, {:room, room.id})
      assert Enum.map(public, &elem(&1, 1)) == [:chat_appended, :room_delta]
      refute dump(public) =~ "chicken"
      refute dump(public) =~ "CHICKEN"
      assert {_, :room_delta, %{correct_guessers: [_], round_summary: nil}} = List.last(public)

      # The slice comes after the public delta of the same guess.
      slice_at = Enum.find_index(messages, &match?({_, :private_state, _}, &1))
      delta_at = Enum.find_index(messages, &match?({_, :room_delta, _}, &1))
      assert delta_at < slice_at
    end

    test "the guesser's view and page carry the answer; nobody else's does before round end",
         ctx do
      %{room: room, first: first, second: second, drawer: drawer} = ctx
      reply = guess!(ctx, first, @word)
      points = reply.next_action.params.points

      {:ok, view} = RoomServer.get_view(room.id, first.id)
      assert view.current_word == @word
      assert view.guess_points == points
      assert view.is_drawer == false
      assert view.word_choices == []

      for viewer <- [second.id, nil, "not-a-member"] do
        {:ok, view} = RoomServer.get_view(room.id, viewer)
        assert view.current_word == nil
        assert view.guess_points == nil
        refute dump(view) =~ "chicken"
      end

      {:ok, drawer_view} = RoomServer.get_view(room.id, drawer.id)
      assert drawer_view.current_word == @word
      assert drawer_view.guess_points == nil

      # A resync is built from the same views.
      resynced = GamePage.command(:resync_room, %{room_id: room.id}, server_for(second))
      refute dump(resynced) =~ "chicken"

      resynced = GamePage.command(:resync_room, %{room_id: room.id}, server_for(first))
      assert resynced.next_action.params.current_word == @word
    end

    test "a player who left after guessing no longer gets the answer", ctx do
      %{room: room, first: first} = ctx
      guess!(ctx, first, @word)
      {:ok, _} = RoomServer.leave(room.id, first.id)

      {:ok, view} = RoomServer.get_view(room.id, first.id)
      assert view.current_word == nil
    end
  end

  describe "the round summary" do
    test "comes only with the round-end delta: answer, points, drawer, next drawer", ctx do
      %{room: room, first: first, second: second, drawer: drawer} = ctx
      subscribe({:room, room.id})

      %{points: points} = guess!(ctx, first, @word).next_action.params
      before_end = drain()
      refute dump(before_end) =~ "round_summary: %{"

      expire_round!(room)
      messages = drain()

      assert [{_, :room_delta, %{phase: :round_end} = delta}] =
               for({_, :room_delta, _} = m <- messages, do: m)

      summary = delta.round_summary
      drawer_points = summary.drawer_points

      assert summary == %{
               round: 1,
               word: @word,
               players: [
                 %{id: first.id, username: first.username, points: points, guessed: true},
                 %{id: second.id, username: second.username, points: 0, guessed: false}
               ],
               drawer_id: drawer.id,
               drawer_name: drawer.username,
               drawer_points: drawer_points,
               next_drawer_name: first.username
             }

      assert drawer_points > 0
      assert struct_free?(summary)
      # No drawing in it: the summary is a few hundred bytes.
      refute Map.has_key?(summary, :drawing_strokes)

      # A page loaded during the pause gets it too.
      assert room_state!(room.id).round_summary == summary
    end

    test "when everyone guessed, highest points first", ctx do
      %{room: room, first: first, second: second} = ctx
      subscribe({:room, room.id})

      %{points: first_points} = guess!(ctx, first, @word).next_action.params
      %{points: second_points} = guess!(ctx, second, @word).next_action.params
      assert first_points > second_points

      assert [{_, :room_delta, %{phase: :round_end, round_summary: summary}}] =
               for({_, :room_delta, %{phase: :round_end}} = m <- drain(), do: m)

      assert Enum.map(summary.players, &{&1.id, &1.points, &1.guessed}) == [
               {first.id, first_points, true},
               {second.id, second_points, true}
             ]
    end

    test "the round-end pause is 5 seconds", %{room: room} do
      assert RoomServer.round_end_ms() == 5_000

      expire_round!(room)
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room.id)
      [advance] = :sys.get_state(pid).turn_timers
      left = Process.read_timer(advance)
      assert left > 4_000 and left <= 5_000
    end
  end
end
