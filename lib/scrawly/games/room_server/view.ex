defmodule Scrawly.Games.RoomServer.View do
  @moduledoc """
  What each viewer of a room may see. Pure functions over `%RoomServer{}`.

  Hologram serializes page state into the HTML and sends command replies and
  broadcasts as plain data, so anything put in these maps reaches the browser.
  The secret word and the drawer's word choices therefore never appear in
  `public/1` or `delta/1` before the round ends; only `for_viewer/2` and
  `private_slice/2` add the word, and only for the current drawer and for a
  player who has guessed it this round (`guessed?/2`). The choices, each
  with its difficulty (`%{text, difficulty}`), go to the drawer alone.

  Every map carries the word as four derived fields:

    * `word_display` - the masked hint for the room's current `hint_stage`
      (`WordHints.hint_for_stage/3`) while `:drawing` or `:round_end`,
      otherwise `""`;
    * `word_length` - the number of letters (spaces, hyphens and apostrophes
      excluded);
    * `revealed_word` - the word itself, only in `:round_end`;
    * `word_difficulty` - the chosen word's difficulty (`:easy`, `:medium`,
      `:hard`) while `:drawing` or `:round_end`, so everyone can see what a
      guess is worth; `nil` for an AI word and in every other phase. Before
      the drawer chooses, no difficulty reaches anyone but the drawer.

  and, only in `:round_end`, the round's results as `round_summary`
  (`round_summary/1`): the answer, every player's points this round, the
  drawer's points and who draws next. `nil` in every other phase.

  No reveal schedule, future mask or letter positions are ever sent: the room
  reveals each stage when it is due and broadcasts the new mask then.

  Time is sent as what is left, in ms, at the moment the map is built:
  `round_remaining_ms` (`:drawing`) and `choice_remaining_ms` (`:choosing`),
  0 otherwise, plus the full `round_duration` / `choice_duration` in seconds.
  Clients anchor those on their own monotonic clock and count down; the
  node-local deadlines themselves are never sent.

  `public/1` and `for_viewer/2` are full snapshots: they carry the room's
  `seq` (the seq of the last `{:room}` broadcast, see
  `RoomServer.Broadcasts`) together with the chat and the strokes, so a page
  that applies one may drop every broadcast up to that seq. `delta/1` carries
  neither chat nor strokes; it gets its own seq when it is published.
  """

  alias Scrawly.Games.{RoomServer, WordHints}
  alias Scrawly.Games.RoomServer.GameFlow

  # Read by GamePage init and :room_resynced, fetch_room_game_settings (the
  # room settings) and GameScorePage (status, post_game_remaining_ms). The
  # home page reads lobby_summary/1 instead.
  @public_keys [
    :room_id,
    :name,
    :code,
    :status,
    :creator_id,
    :max_players,
    :players,
    :watchers,
    :seq,
    :game_id,
    :current_round,
    :total_rounds,
    :current_drawer_id,
    :round_active,
    :correct_guessers,
    :chat_messages,
    :drawing_strokes,
    :last_game_id,
    :answer_kind,
    :word_source,
    :prompt,
    :creator_name,
    :round_duration,
    :round_multiplier,
    :ai_tone,
    :past_games,
    :phase
  ]

  # The settings the host can change in the lobby (settings/1).
  # round_duration also goes out as a derived field.
  @settings_keys [
    :name,
    :max_players,
    :answer_kind,
    :word_source,
    :prompt,
    :round_duration,
    :round_multiplier,
    :ai_tone
  ]

  # The `:room_delta` broadcast to everyone in the room (its `seq` is put by
  # Broadcasts.publish/3, one higher than the room's). `past_games` only
  # changes when a game ends, and every page leaves for the score page then,
  # so it goes in snapshots only. The settings ride along in every delta
  # (they are small and public), so a lobby page shows the host's change
  # with the delta that carries it.
  @delta_keys [
    :room_id,
    :status,
    :players,
    :watchers,
    :game_id,
    :current_round,
    :total_rounds,
    :current_drawer_id,
    :round_active,
    :correct_guessers,
    :phase,
    :last_game_id
    | @settings_keys
  ]

  @doc """
  The room as anyone may see it: no word, no word choices, no choice deadline.
  Used for `get_state/1` and the RoomServer call replies.

  Also carries `post_game_remaining_ms`: the ms left before a `:post_game`
  room returns to the lobby (never negative), `nil` in any other status. The
  deadline itself is node-local monotonic time and is never sent.
  """
  @spec public(struct) :: map
  def public(state) do
    state
    |> Map.take(@public_keys)
    |> Map.merge(derived_fields(state))
    |> Map.put(:post_game_remaining_ms, post_game_remaining_ms(state))
  end

  @doc "The `:room_delta` payload: `public/1`'s live fields, also word-free."
  @spec delta(struct) :: map
  def delta(state) do
    state
    |> Map.take(@delta_keys)
    |> Map.merge(derived_fields(state))
  end

  @doc """
  The room's settings, the ones the host can change in the lobby
  (`RoomServer.update_settings/3`): `name`, `max_players`, `answer_kind`,
  `word_source`, `prompt`, `round_duration`, `round_multiplier` and
  `ai_tone`. Every `public/1` and `delta/1` map carries them.
  """
  @spec settings(map) :: map
  def settings(state), do: Map.take(state, @settings_keys)

  @doc """
  `public/1` plus the per-viewer keys the game page reads, always present:

    * `is_drawer` - `viewer_id` is a binary equal to `current_drawer_id` and
      still one of the room's players (never true for a `nil` viewer, even
      when there is no drawer, nor for a drawer who left);
    * `drawer_name` - the drawer's username, or `"Unknown"`;
    * `current_word` - the word for the drawer and for a player who has
      guessed it this round (`guessed?/2`), otherwise `nil`;
    * `word_choices` - the drawer's choices, otherwise `[]`;
    * `guess_points` - the points a player who has guessed the word this
      round scored for it, otherwise `nil`.
  """
  @spec for_viewer(struct, term) :: map
  def for_viewer(state, viewer_id) do
    state
    |> public()
    |> Map.put(:drawer_name, GameFlow.get_player_name(state.players, state.current_drawer_id))
    |> Map.merge(viewer_fields(state, viewer_id))
  end

  @doc """
  The current drawer's private slice (`private_slice/2` for the drawer).
  """
  @spec private_slice(struct) :: map
  def private_slice(state), do: private_slice(state, state.current_drawer_id)

  @doc """
  `viewer_id`'s private slice, sent only on their own `{:room_player}`
  channel (and in the drawer's `choose_word` reply): `for_viewer/2`'s word
  fields for the turn that `game_id` and `round` name. The drawer gets the
  word choices while `:choosing` and the word once committed; a player who
  has just guessed the word gets it, plus their `guess_points`; anyone else
  gets no word. Carries no seq.
  """
  @spec private_slice(struct, term) :: map
  def private_slice(state, viewer_id) do
    fields = viewer_fields(state, viewer_id)

    slice = %{
      game_id: state.game_id,
      round: state.current_round,
      phase: state.phase,
      current_word: fields.current_word,
      word_choices: fields.word_choices
    }

    if fields.guess_points,
      do: Map.put(slice, :guess_points, fields.guess_points),
      else: slice
  end

  @doc """
  Whether `user_id` is one of the room's players and has guessed the word
  this round (they are in `correct_guessers`). Such a player may see the
  word before the round ends (`for_viewer/2`, `private_slice/2`).
  """
  @spec guessed?(map, term) :: boolean
  def guessed?(state, user_id) do
    is_binary(user_id) and user_id in (state.correct_guessers || []) and
      Enum.any?(state.players || [], &(&1.id == user_id))
  end

  # The word fields only some viewers get: the drawer (word and choices) and
  # a player who has guessed the word (word and points).
  defp viewer_fields(state, viewer_id) do
    cond do
      drawer?(state, viewer_id) ->
        %{
          is_drawer: true,
          current_word: state.current_word,
          word_choices: state.word_choices || [],
          guess_points: nil
        }

      guessed?(state, viewer_id) ->
        %{
          is_drawer: false,
          current_word: state.current_word,
          word_choices: [],
          guess_points: points_this_round(state, viewer_id)
        }

      true ->
        %{is_drawer: false, current_word: nil, word_choices: [], guess_points: nil}
    end
  end

  # A player's points since the round began (a guesser's are their guess's).
  defp points_this_round(state, player_id) do
    case Enum.find(state.players || [], &(&1.id == player_id)) do
      nil -> 0
      player -> (player.score || 0) - Map.get(state.round_start_scores || %{}, player_id, 0)
    end
  end

  @doc """
  What the home page's room list (`ScrawlyWeb.Components.RoomList`) shows of
  a room, and nothing else: no chat, no past games, no creator or player ids.
  Players are reduced to their avatars. Sent in `HomePage.init/3` and in the
  `:lobby_room_changed` broadcast.
  """
  @spec lobby_summary(struct) :: map
  def lobby_summary(state) do
    %{
      room_id: state.room_id,
      name: state.name,
      code: state.code,
      status: state.status,
      max_players: state.max_players,
      answer_kind: state.answer_kind,
      word_source: state.word_source,
      # The room list shows a themed room's theme; other rooms keep none.
      prompt: if(state.word_source == :ai, do: state.prompt),
      round_duration: state.round_duration,
      round_multiplier: state.round_multiplier,
      players:
        Enum.map(state.players, fn player ->
          %{avatar_id: Map.get(player, :avatar_id), avatar_color: Map.get(player, :avatar_color)}
        end)
    }
  end

  @doc """
  Whether `user_id` is the room's current drawer: a binary equal to
  `current_drawer_id` that is still one of the room's players. Only the
  drawer may draw (`RoomServer.authorize/3` `:draw`) and see the word.
  """
  @spec drawer?(map, term) :: boolean
  def drawer?(state, user_id) do
    is_binary(user_id) and user_id == state.current_drawer_id and
      Enum.any?(state.players || [], &(&1.id == user_id))
  end

  defp derived_fields(state) do
    word = shown_word(state)
    now = System.monotonic_time(:millisecond)

    %{
      word_display: WordHints.hint_for_stage(word, state.hint_stage || 0),
      word_length: WordHints.word_length_hint(word),
      revealed_word: if(state.phase == :round_end, do: word),
      word_difficulty: if(word, do: Map.get(state, :current_difficulty)),
      round_summary: round_summary(state),
      round_remaining_ms: RoomServer.round_remaining_ms(state, now),
      choice_remaining_ms: RoomServer.choice_remaining_ms(state, now),
      round_duration: state.round_duration || 60,
      choice_duration: GameFlow.choice_duration()
    }
  end

  @doc """
  The finished round as everyone sees it during the `:round_end` pause, or
  `nil` in any other phase and when the round has no result (a drawer who
  left while choosing: no word was drawn).

    * `round`, `word`, `difficulty` - the round, its answer and the
      answer's difficulty (`nil` for an AI word);
    * `players` - every player but the drawer as `%{id, username, points,
      guessed}`, the highest `points` first (players with equal points keep
      the room's order);
    * `drawer_id`, `drawer_name`, `drawer_points` - who drew and what it
      earned them;
    * `next_drawer_name` - who draws next, or `nil` when the game ends
      after this round.

  Built from the round's result (`GameFlow.capture_round_result/3`), minus
  its drawing.
  """
  @spec round_summary(struct) :: map | nil
  def round_summary(%{phase: :round_end} = state) do
    case List.last(state.round_results || []) do
      %{round: round} = result when round == state.current_round ->
        %{
          round: round,
          word: Map.get(result, :word),
          difficulty: Map.get(result, :difficulty),
          players:
            result
            |> Map.get(:player_scores, [])
            |> Enum.reject(&(Map.get(&1, :is_drawer) == true))
            |> Enum.map(&summary_row/1)
            |> Enum.sort_by(& &1.points, :desc),
          drawer_id: Map.get(result, :drawer_id),
          drawer_name: Map.get(result, :drawer_name),
          drawer_points: Map.get(result, :drawer_points) || 0,
          next_drawer_name: next_drawer_name(state)
        }

      _no_result ->
        nil
    end
  end

  def round_summary(_state), do: nil

  defp summary_row(row) do
    %{
      id: Map.get(row, :id),
      username: Map.get(row, :username),
      points: Map.get(row, :points) || 0,
      guessed: Map.get(row, :guessed) == true
    }
  end

  # The first queued drawer who is still a player (GameFlow.start_word_choice/3
  # picks the same one), unless the game ends after this round (the room's
  # :auto_advance_round decides the same way).
  defp next_drawer_name(state) do
    player_ids = MapSet.new(state.players || [], & &1.id)

    with true <- state.current_round < state.total_rounds,
         id when id != nil <- Enum.find(state.turn_queue || [], &MapSet.member?(player_ids, &1)) do
      GameFlow.get_player_name(state.players, id)
    else
      _game_ends -> nil
    end
  end

  # The word only exists for viewers while it is being drawn or just revealed.
  defp shown_word(%{phase: phase, current_word: word})
       when phase in [:drawing, :round_end] and is_binary(word),
       do: word

  defp shown_word(_state), do: nil

  defp post_game_remaining_ms(%{status: :post_game, post_game_deadline: deadline})
       when is_integer(deadline),
       do: max(0, deadline - System.monotonic_time(:millisecond))

  defp post_game_remaining_ms(_state), do: nil
end
