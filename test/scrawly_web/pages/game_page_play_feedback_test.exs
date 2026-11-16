defmodule ScrawlyWeb.Pages.GamePagePlayFeedbackTest do
  @moduledoc """
  Play feedback on the game page (play-feedback), against a live room:

    * blanks as one block per word, labelled "4 words · 22 letters";
    * a player who guessed sees the answer and "you got it · +N" at once
      (header and chat input), and everyone sees a tick beside their name
      and a pencil beside the drawer's;
    * a player who has not guessed never holds the answer before the round
      ends: not in the rendered markup, not in the page state Hologram
      serializes into the page;
    * the round summary covers the canvas during the `:round_end` pause.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Hologram.Compiler.Encoder
  alias Hologram.Template.Renderer
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  @word "chicken crossing the road"

  setup do
    drawer = create_user()
    guesser = create_user()
    other = create_user()
    room = start_room(drawer)

    for user <- [guesser, other] do
      assert GamePage.command(:join_room, %{room_id: room.id}, server_for(user)).next_action.name ==
               :room_resynced
    end

    start_drawing!(room, drawer, @word)
    %{room: room, drawer: drawer, guesser: guesser, other: other}
  end

  defp init_page(room, server) do
    {component, _server} =
      GamePage.init(%{room_id: room.id}, %Hologram.Component{props: %{room_id: room.id}}, server)

    %{component | next_action: nil}
  end

  defp render(component) do
    {html, _registry, _server} =
      GamePage.template().(Map.merge(component.props, component.state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  # What a document load embeds of the page: its markup and its state, in
  # the encoding Hologram serializes component state with.
  defp page_output(component), do: render(component) <> Encoder.encode_term!(component.state)

  defp refute_answer(text) do
    for form <- [@word, String.upcase(@word), "chicken", "CHICKEN", "crossing", "CROSSING"] do
      refute text =~ form, "#{inspect(form)} leaked"
    end
  end

  defp guess!(ctx, user, text) do
    GamePage.command(:submit_guess, %{room_id: ctx.room.id, text: text}, server_for(user))
  end

  defp subscribe(channel),
    do: Phoenix.PubSub.subscribe(Hologram.PubSub, Hologram.Realtime.channel_topic(channel))

  defp drain(acc \\ []) do
    receive do
      {:broadcast_action, _channel, action, params, _except} -> drain([{action, params} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp chunks(html, class) do
    [_, block] = Regex.run(~r/<div class="#{class}">(.*?)<\/div>/s, html)

    Regex.scan(~r/<span class="word-chunk">([^<]*)<\/span>/, block, capture: :all_but_first)
    |> List.flatten()
  end

  describe "the blanks" do
    test "one block per word, and the label gives the words and the letters", ctx do
      html = render(init_page(ctx.room, server_for(ctx.guesser)))

      assert chunks(html, "word-letters masked") ==
               ["_ _ _ _ _ _ _", "_ _ _ _ _ _ _ _", "_ _ _", "_ _ _ _"]

      assert html =~ "round 1 of 3 · 4 words · 22 letters"
    end

    test "letters revealed by a hint stay in their word's block", ctx do
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, ctx.room.id)
      %{game_id: game_id} = :sys.get_state(pid)
      send(pid, {:hint_reveal, game_id, 1, 2})
      assert :sys.get_state(pid).hint_stage == 2

      html = render(init_page(ctx.room, server_for(ctx.other)))
      blocks = chunks(html, "word-letters masked")
      assert length(blocks) == 4
      assert Enum.join(blocks, "   ") == Scrawly.Games.WordHints.hint_for_stage(@word, 2)
      assert Enum.any?(blocks, &(&1 =~ ~r/[a-z]/))
    end

    test "the drawer's own word wraps between words too", ctx do
      html = render(init_page(ctx.room, server_for(ctx.drawer)))
      assert chunks(html, "word-letters") == ["CHICKEN", "CROSSING", "THE", "ROAD"]
      assert html =~ "your word · 4 words · 22 letters"
    end

    # String.split/2 compiles a binary pattern that Hologram 0.12.8's client
    # runtime registers and never frees: split on every render, the game page
    # grew by ~4 KB per action (notes/files/drawing-benchmarks.md).
    test "the blocks are worked out when the word changes, never by a render", ctx do
      source = File.read!("lib/scrawly_web/pages/game_page.ex")
      [_code, template] = String.split(source, "def template do", parts: 2)

      for helper <- ~w(mask_blocks word_blocks word_label) do
        refute template =~ "PlayFeedback.#{helper}",
               "the template calls PlayFeedback.#{helper} on every render"
      end

      page = init_page(ctx.room, server_for(ctx.other))
      view = page.state.word_view
      assert view.mask == ["_ _ _ _ _ _ _", "_ _ _ _ _ _ _ _", "_ _ _", "_ _ _ _"]

      # An action that changes no word field keeps the very blocks it had.
      tick = GamePage.action(:countdown_tick, %{gen: page.state.tick_gen}, page)
      assert tick.state.word_view == view

      # A hint does change them (here through a snapshot of the room).
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, ctx.room.id)
      send(pid, {:hint_reveal, :sys.get_state(pid).game_id, 1, 2})
      {:ok, view} = Scrawly.Games.RoomServer.get_view(ctx.room.id, ctx.other.id)
      hinted = GamePage.action(:room_resynced, view, page)

      assert Enum.join(hinted.state.word_view.mask, "   ") == view.word_display

      assert hinted.state.word_view.mask !=
               view.word_display |> String.replace(~r/[a-z]/, "_") |> String.split("   ")
    end
  end

  describe "you got it" do
    test "the guesser sees the answer and their points; the board ticks them for all", ctx do
      %{points: points} = guess!(ctx, ctx.guesser, @word).next_action.params
      got_it = "you got it · +#{points}"

      page = init_page(ctx.room, server_for(ctx.guesser))
      assert page.state.current_word == @word
      assert page.state.guess_points == points

      html = render(page)
      assert chunks(html, "word-letters got-it") == ["CHICKEN", "CROSSING", "THE", "ROAD"]
      assert html =~ ~s(<span class="got-it">#{got_it}</span>)
      assert html =~ ~s(placeholder="#{got_it}")
      # Chat stays open.
      refute html =~ ~r/<input[^>]*name="message"[^>]*disabled/

      for user <- [ctx.guesser, ctx.other, ctx.drawer] do
        board = render(init_page(ctx.room, server_for(user)))
        assert length(Regex.scan(~r/aria-label="guessed it"/, board)) == 1
        assert length(Regex.scan(~r/aria-label="drawing"/, board)) == 1
      end
    end

    test "a player who has not guessed never holds the answer during drawing", ctx do
      guess!(ctx, ctx.guesser, @word)

      for server <- [
            server_for(ctx.other),
            anon_server("anon-#{System.unique_integer([:positive])}")
          ] do
        page = init_page(ctx.room, server)
        assert page.state.current_word == nil
        assert page.state.guess_points == nil
        assert page.state.round_summary == nil
        refute_answer(page_output(page))

        assert render(page) =~ ~s(placeholder="type a guess...") or
                 page.state.current_user_id == nil
      end
    end

    test "the guess reply keeps the points at once and checks the word arrives", ctx do
      page = init_page(ctx.room, server_for(ctx.guesser))
      reply = guess!(ctx, ctx.guesser, @word)
      points = reply.next_action.params.points

      result = GamePage.action(:guess_result, reply.next_action.params, page)
      assert result.state.guess_points == points
      assert result.next_action.name == :check_guessed_word
      assert result.next_action.delay == 1_500
      assert render(result) =~ ~s(placeholder="you got it · +#{points}")

      # The word came on the user's own channel: nothing to do.
      slice = %{
        game_id: page.state.game_id,
        round: 1,
        phase: :drawing,
        current_word: @word,
        word_choices: [],
        guess_points: points
      }

      with_word = GamePage.action(:private_state, slice, %{result | next_action: nil})
      assert with_word.state.current_word == @word
      checked = GamePage.action(:check_guessed_word, result.next_action.params, with_word)
      assert checked.next_command == nil

      # It never came (the push was lost): the page resyncs, and the snapshot
      # brings it.
      lost = GamePage.action(:check_guessed_word, result.next_action.params, result)
      assert lost.next_command.name == :resync_room

      snapshot =
        GamePage.command(:resync_room, %{room_id: ctx.room.id}, server_for(ctx.guesser)).next_action.params

      restored = GamePage.action(:room_resynced, snapshot, lost)
      assert restored.state.current_word == @word
      assert restored.state.guess_points == points
    end

    test "a new turn forgets the guess", ctx do
      page = init_page(ctx.room, server_for(ctx.guesser))
      %{points: points} = guess!(ctx, ctx.guesser, @word).next_action.params
      page = GamePage.action(:guess_result, %{outcome: :correct, points: points}, page)

      subscribe({:room, ctx.room.id})
      expire_round!(ctx.room)
      [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, ctx.room.id)
      send(pid, :auto_advance_round)
      assert room_state!(ctx.room.id).phase == :choosing

      page =
        drain()
        |> Enum.filter(&match?({:room_delta, _}, &1))
        |> Enum.reduce(%{page | next_action: nil}, fn {:room_delta, delta}, acc ->
          GamePage.action(:room_delta, delta, acc)
        end)

      assert page.state.phase == :choosing
      assert page.state.guess_points == nil
      assert page.state.current_word == nil
      assert page.state.round_summary == nil
    end
  end

  describe "the round summary" do
    test "covers the canvas during the pause, for everyone", ctx do
      %{points: points} = guess!(ctx, ctx.guesser, @word).next_action.params
      page = init_page(ctx.room, server_for(ctx.other))
      refute render(page) =~ "round-summary"

      subscribe({:room, ctx.room.id})
      expire_round!(ctx.room)

      [delta] = for {:room_delta, %{phase: :round_end} = delta} <- drain(), do: delta
      ended = GamePage.action(:room_delta, delta, page)
      assert ended.state.round_summary == delta.round_summary

      html = render(ended)
      assert html =~ "round 1 · the answer was"

      assert chunks(html, "word-letters round-summary-answer") == [
               "CHICKEN",
               "CROSSING",
               "THE",
               "ROAD"
             ]

      rows =
        Regex.scan(
          ~r/<div class="round-summary-row[^"]*">.*?<\/span>\s*([^<]+?)\s*(?:<span class="role">drew<\/span>\s*)?<\/span>\s*<span class="pts mono[^"]*">([^<]+)<\/span>/s,
          html,
          capture: :all_but_first
        )

      assert rows == [
               [ctx.guesser.username, "+#{points}"],
               [ctx.other.username, "—"],
               [ctx.drawer.username, "+#{delta.round_summary.drawer_points}"]
             ]

      assert html =~ "next: #{ctx.guesser.username} draws"
      # The viewer's own row stands out.
      assert html =~ ~s(<div class="round-summary-row me">)

      # A page loaded during the pause shows it too.
      assert render(init_page(ctx.room, server_for(ctx.drawer))) =~ "round 1 · the answer was"
    end
  end
end
