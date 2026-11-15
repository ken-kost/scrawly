defmodule Scrawly.Games.RoomServer.View do
  @moduledoc """
  What each viewer of a room may see. Pure functions over `%RoomServer{}`.

  Hologram serializes page state into the HTML and sends command replies and
  broadcasts as plain data, so anything put in these maps reaches the browser.
  The secret word and the drawer's word choices therefore never appear in
  `public/1` or `delta/1`; only `for_viewer/2` adds them, and only when the
  viewer is the current drawer.

  Every map carries the word as three derived fields:

    * `word_display` - the masked hint for the room's current `hint_stage`
      (`WordHints.hint_for_stage/3`) while `:drawing` or `:round_end`,
      otherwise `""`;
    * `word_length` - the number of letters (spaces, hyphens and apostrophes
      excluded);
    * `revealed_word` - the word itself, only in `:round_end`.

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
    :word_count,
    :word_source,
    :prompt,
    :creator_name,
    :round_duration,
    :round_multiplier,
    :ai_tone,
    :past_games,
    :phase
  ]

  # The `:room_delta` broadcast to everyone in the room (its `seq` is put by
  # Broadcasts.publish/3, one higher than the room's). `past_games` only
  # changes when a game ends, and every page leaves for the score page then,
  # so it goes in snapshots only.
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
    :last_game_id,
    :max_players
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
  `public/1` plus the per-viewer keys the game page reads, always present:

    * `is_drawer` - `viewer_id` is a binary equal to `current_drawer_id` and
      still one of the room's players (never true for a `nil` viewer, even
      when there is no drawer, nor for a drawer who left);
    * `drawer_name` - the drawer's username, or `"Unknown"`;
    * `current_word` - the word for the drawer, otherwise `nil`;
    * `word_choices` - the drawer's choices, otherwise `[]`.
  """
  @spec for_viewer(struct, term) :: map
  def for_viewer(state, viewer_id) do
    is_drawer = drawer?(state, viewer_id)

    state
    |> public()
    |> Map.merge(%{
      is_drawer: is_drawer,
      drawer_name: GameFlow.get_player_name(state.players, state.current_drawer_id),
      current_word: if(is_drawer, do: state.current_word),
      word_choices: if(is_drawer, do: state.word_choices || [], else: [])
    })
  end

  @doc """
  The drawer's private slice, sent only on their own `{:room_player}` channel
  and in their `choose_word` reply: the word choices while `:choosing`, the
  word once committed. `game_id` and `round` say which turn it belongs to.
  Carries no seq.
  """
  @spec private_slice(struct) :: map
  def private_slice(state) do
    %{
      game_id: state.game_id,
      round: state.current_round,
      phase: state.phase,
      current_word: state.current_word,
      word_choices: state.word_choices || []
    }
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
      word_source: state.word_source,
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
      round_remaining_ms: RoomServer.round_remaining_ms(state, now),
      choice_remaining_ms: RoomServer.choice_remaining_ms(state, now),
      round_duration: state.round_duration || 60,
      choice_duration: GameFlow.choice_duration()
    }
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
