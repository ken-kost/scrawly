defmodule Scrawly.Games.RoomServer.View do
  @moduledoc """
  What each viewer of a room may see. Pure functions over `%RoomServer{}`.

  Hologram serializes page state into the HTML and sends command replies and
  broadcasts as plain data, so anything put in these maps reaches the browser.
  The secret word and the drawer's word choices therefore never appear in
  `public/1` or `delta/1`; only `for_viewer/2` adds them, and only when the
  viewer is the current drawer.

  Every map carries the word as three derived fields:

    * `word_display` - the masked hint (`WordHints.generate_hint/3`) while
      `:drawing` or `:round_end`, otherwise `""`;
    * `word_length` - the number of letters (spaces and hyphens excluded);
    * `revealed_word` - the word itself, only in `:round_end`.

  No reveal schedule, future mask or letter positions are ever sent: the hint
  is recomputed from `time_left` on every tick.
  """

  alias Scrawly.Games.WordHints
  alias Scrawly.Games.RoomServer.GameFlow

  # Read by GamePage init and room_refreshed, HomePage (name, code, players,
  # max_players), fetch_room_game_settings (the room settings) and
  # GameScorePage (status).
  @public_keys [
    :room_id,
    :name,
    :code,
    :status,
    :creator_id,
    :max_players,
    :players,
    :watchers,
    :version,
    :game_id,
    :current_round,
    :total_rounds,
    :current_drawer_id,
    :time_left,
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

  # The `:room_delta` broadcast to everyone in the room.
  @delta_keys [
    :room_id,
    :status,
    :players,
    :watchers,
    :version,
    :game_id,
    :current_round,
    :total_rounds,
    :current_drawer_id,
    :time_left,
    :round_active,
    :correct_guessers,
    :phase,
    :last_game_id,
    :max_players,
    :past_games
  ]

  @doc """
  The room as anyone may see it: no word, no word choices, no choice deadline.
  Used for `get_state/1` and the RoomServer call replies.
  """
  @spec public(struct) :: map
  def public(state) do
    state
    |> Map.take(@public_keys)
    |> Map.merge(derived_fields(state))
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

    * `is_drawer` - `viewer_id` is a binary equal to `current_drawer_id`
      (never true for a `nil` viewer, even when there is no drawer);
    * `drawer_name` - the drawer's username, or `"Unknown"`;
    * `current_word` - the word for the drawer, otherwise `nil`;
    * `word_choices` - the drawer's choices, otherwise `[]`.
  """
  @spec for_viewer(struct, term) :: map
  def for_viewer(state, viewer_id) do
    is_drawer = is_binary(viewer_id) and viewer_id == state.current_drawer_id

    state
    |> public()
    |> Map.merge(%{
      is_drawer: is_drawer,
      drawer_name: GameFlow.get_player_name(state.players, state.current_drawer_id),
      current_word: if(is_drawer, do: state.current_word),
      word_choices: if(is_drawer, do: state.word_choices || [], else: [])
    })
  end

  defp derived_fields(state) do
    word = shown_word(state)

    %{
      word_display: word_display(word, state),
      word_length: WordHints.word_length_hint(word),
      revealed_word: if(state.phase == :round_end, do: word),
      choice_time_left: choice_time_left(state)
    }
  end

  # The word only exists for viewers while it is being drawn or just revealed.
  defp shown_word(%{phase: phase, current_word: word})
       when phase in [:drawing, :round_end] and is_binary(word),
       do: word

  defp shown_word(_state), do: nil

  defp word_display(nil, _state), do: ""

  defp word_display(word, state),
    do: WordHints.generate_hint(word, state.time_left || 0, state.round_duration || 60)

  defp choice_time_left(%{choice_deadline: deadline}) when is_integer(deadline) do
    now = System.monotonic_time(:millisecond)
    max(0, div(deadline - now + 999, 1000))
  end

  defp choice_time_left(_state), do: 0
end
