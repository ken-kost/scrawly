defmodule ScrawlyWeb.Pages.GamePage.Commands do
  @moduledoc """
  Server-side command logic for GamePage.

  All functions here run exclusively on the server — never compiled to JS by Hologram.
  They receive a `%Hologram.Server{}` struct and return one (possibly with a next_action).

  The acting user always comes from the session via `ScrawlyWeb.Auth`, never from
  params. Rejected commands reply with `:command_denied` (see `Auth.deny/3`).
  """

  require Logger

  import Hologram.Component, only: [put_action: 2, put_action: 3, put_broadcast_except: 5]

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.{WordHints, RoomServer}
  alias Scrawly.Games.RoomServer.GameFlow
  alias ScrawlyWeb.Auth

  def poll_room_state(%{room_id: room_id}, server) do
    poll_and_enrich(server, room_id, Auth.user_id(server))
  end

  def join_room(%{room_id: room_id}, server) do
    case Auth.current_user(server) do
      {:ok, user} ->
        player = %{
          id: user.id,
          username: user.username,
          score: user.score || 0,
          avatar_id: user.avatar_id || "a-mushroom",
          avatar_color: user.avatar_color || "3"
        }

        case RoomServer.join(room_id, player) do
          {:ok, _state} ->
            Accounts.join_room(user, room_id)
            Games.join_room(room_id, user.id)

            poll_and_enrich(server, room_id, user.id)

          {:error, :room_full} ->
            put_action(server, :switch_to_watcher)

          {:error, _} ->
            server
        end

      {:error, reason} ->
        Auth.deny(server, :join_room, reason)
    end
  end

  def join_as_watcher(%{room_id: room_id}, server) do
    case Auth.actor_key(server) do
      nil ->
        Auth.deny(server, :join_as_watcher, :unauthenticated)

      key ->
        username =
          case Auth.current_user(server) do
            {:ok, user} -> user.username || "Guest"
            {:error, _} -> "Guest"
          end

        case RoomServer.join_as_watcher(room_id, %{id: key, username: username}) do
          {:ok, state} -> put_action(server, :room_refreshed, state)
          {:error, :room_full} -> Auth.deny(server, :join_as_watcher, :room_full)
          {:error, _} -> server
        end
    end
  end

  def leave_watcher(%{room_id: room_id}, server) do
    if key = Auth.actor_key(server), do: RoomServer.leave_watcher(room_id, key)
    put_action(server, :go_home)
  end

  def start_game(%{room_id: room_id}, server) do
    with {:ok, uid} <- session_user_id(server),
         {:ok, state} <- RoomServer.get_state(room_id),
         :ok <- RoomServer.authorize(state, uid, :start_game) do
      # Only reached by an authorized creator: this may make an AI call.
      {word_count, ai_words, ai_status} = fetch_room_game_settings(state)

      {choices, remaining_ai, _used_from_ai} =
        GameFlow.pick_word_choices(ai_words, [], word_count, 3)

      case RoomServer.start_game(room_id, uid, %{word_choices: choices, ai_words: remaining_ai}) do
        {:ok, _state} ->
          if ai_status, do: RoomServer.system_message(room_id, ai_status)

          case RoomServer.get_state(room_id) do
            {:ok, state} -> put_action(server, :room_refreshed, enrich_state(state, uid))
            _ -> server
          end

        {:error, reason} ->
          Auth.deny(server, :start_game, reason)
      end
    else
      {:error, reason} -> Auth.deny(server, :start_game, reason)
    end
  end

  def choose_word(%{room_id: room_id, player_id: player_id, word: word}, server) do
    case RoomServer.choose_word(room_id, player_id, word) do
      {:ok, _state} ->
        case RoomServer.get_state(room_id) do
          {:ok, state} ->
            put_action(server, :room_refreshed, enrich_state(state, player_id))

          _ ->
            server
        end

      {:error, _} ->
        server
    end
  end

  @doc """
  Leaves `room_id` as the session user, then puts `done_action` (`:go_home` on
  GamePage, `:left_room` on GameScorePage). Shared by both pages.

  The creator leaving dissolves the room. Leaving is idempotent: a user who is
  no longer in the RoomServer (e.g. after `:return_to_lobby` emptied `players`)
  still gets their DB membership for this room cleared, without a denial.
  Visitors without an account just navigate.
  """
  def leave_room(%{room_id: room_id}, server, done_action \\ :go_home) do
    with {:ok, user} <- Auth.current_user(server) do
      case RoomServer.leave(room_id, user.id) do
        {:ok, :dissolved} ->
          Games.dissolve_room(room_id)

        {:ok, _state} ->
          Accounts.leave_room(user)

        {:error, :not_member} ->
          clear_membership(user, room_id)

        {:error, :not_found} ->
          if db_creator?(room_id, user.id),
            do: Games.dissolve_room(room_id),
            else: clear_membership(user, room_id)
      end
    end

    put_action(server, done_action)
  end

  @doc """
  Dissolves `room_id` if the session user is its creator, then puts
  `done_action`. Anyone else is denied and nothing changes. When the RoomServer
  is already gone, the DB room is dissolved only if its `creator_id` matches.
  """
  def dissolve_room(%{room_id: room_id}, server, done_action) do
    with {:ok, uid} <- session_user_id(server),
         :ok <- dissolve_room_server(room_id, uid) do
      Games.dissolve_room(room_id)
      put_action(server, done_action)
    else
      {:error, reason} -> Auth.deny(server, :dissolve_room, reason)
    end
  end

  @doc """
  Submits a chat line or guess as the session user. Only `room_id` and `text`
  are read from params; identity, display name and points never come from the
  client. The room process checks the guess (`RoomServer.submit_message/3`);
  on a correct guess the session user's stored score is raised atomically.

  Replies `:guess_result` with `outcome` (`:correct` also carries `points`), or
  `:command_denied` for visitors without an account, non-members and rooms
  that no longer exist.
  """
  def submit_guess(params, server) do
    case Auth.user_id(server) do
      nil ->
        Auth.deny(server, :submit_guess, :unauthenticated)

      uid ->
        case RoomServer.submit_message(Map.get(params, :room_id), uid, Map.get(params, :text)) do
          {:ok, {:correct, points}} ->
            persist_guess_points(uid, points)
            put_action(server, :guess_result, outcome: :correct, points: points)

          {:ok, outcome} ->
            put_action(server, :guess_result, outcome: outcome)

          {:error, :not_in_room} ->
            Auth.deny(server, :submit_guess, :not_member)

          {:error, :not_found} ->
            Auth.deny(server, :submit_guess, :not_found)

          {:error, reason} ->
            put_action(server, :guess_result, outcome: reason)
        end
    end
  end

  def complete_stroke(
        %{room_id: room_id, stroke_id: stroke_id, path: path, color: color, width: width} =
          params,
        server
      ) do
    RoomServer.append_drawing(room_id, %{path: path, color: color, width: width})

    put_broadcast_except(
      server,
      {:user, params[:user_id]},
      {:room, room_id},
      :stroke_completed,
      %{stroke_id: stroke_id, path: path, color: color, width: width}
    )
  end

  def clear_drawing_cmd(%{room_id: room_id} = params, server) do
    RoomServer.clear_drawing(room_id)

    put_broadcast_except(
      server,
      {:user, params[:user_id]},
      {:room, room_id},
      :drawing_cleared,
      %{}
    )
  end

  def undo_drawing_cmd(%{room_id: room_id} = params, server) do
    case RoomServer.undo_drawing(room_id) do
      {:ok, strokes} ->
        put_broadcast_except(
          server,
          {:user, params[:user_id]},
          {:room, room_id},
          :drawing_undone,
          %{strokes: strokes}
        )

      _ ->
        server
    end
  end

  defp dissolve_room_server(room_id, uid) do
    case RoomServer.dissolve_room(room_id, uid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        case Games.get_room_by_id(room_id) do
          {:ok, %{creator_id: ^uid}} -> :ok
          {:ok, _room} -> {:error, :not_creator}
          {:error, _} -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp db_creator?(room_id, uid) do
    match?({:ok, %{creator_id: ^uid}}, Games.get_room_by_id(room_id))
  end

  # Only clear the account's room membership if it points at this room, so a
  # stale "leave" can't pull the user out of a room they have since joined.
  defp clear_membership(user, room_id) do
    if user.current_room_id == room_id, do: Accounts.leave_room(user)
  end

  defp session_user_id(server) do
    case Auth.user_id(server) do
      nil -> {:error, :unauthenticated}
      uid -> {:ok, uid}
    end
  end

  # Runs after the room call has already scored the guess: a failed DB write is
  # logged, never retried through the room process.
  defp persist_guess_points(uid, points) do
    case Accounts.add_score(uid, points) do
      {:ok, _user} ->
        :ok

      {:error, error} ->
        Logger.error("could not add #{points} points to user #{inspect(uid)}: #{inspect(error)}")
    end
  end

  defp poll_and_enrich(server, room_id, user_id) do
    case RoomServer.get_state(room_id) do
      {:ok, state} ->
        put_action(server, :room_refreshed, enrich_state(state, user_id))

      {:error, :not_found} ->
        put_action(server, :room_dissolved)
    end
  end

  defp enrich_state(state, user_id) do
    is_drawer = state.current_drawer_id == user_id
    game_active = state.game_id != nil
    word = state.current_word || ""
    phase = Map.get(state, :phase, :idle)

    word_display =
      cond do
        not game_active ->
          ""

        phase == :choosing ->
          ""

        is_drawer ->
          word

        state.time_left > 0 ->
          WordHints.generate_hint(word, state.time_left, state.round_duration || 60)

        true ->
          WordHints.hidden_display(word, state.round_duration || 60)
      end

    drawer_name =
      case Enum.find(state.players, &(&1.id == state.current_drawer_id)) do
        nil -> "Unknown"
        p -> p.username
      end

    hint_info =
      if game_active and not is_drawer and phase == :drawing do
        WordHints.hint_info(word, state.time_left, state.round_duration || 60)
      else
        %{stage: 0, revealed_count: 0, total_letters: 0, remaining_count: 0, progress_pct: 0}
      end

    word_choices = if is_drawer, do: Map.get(state, :word_choices, []), else: []

    choice_time_left =
      case Map.get(state, :choice_deadline) do
        nil ->
          0

        deadline when is_integer(deadline) ->
          now = System.monotonic_time(:millisecond)
          max(0, div(deadline - now + 999, 1000))
      end

    state
    |> Map.merge(%{
      is_drawer: is_drawer,
      current_word_display: word_display,
      drawer_name: drawer_name,
      hint_info: hint_info,
      word_choices: word_choices,
      choice_time_left: choice_time_left,
      phase: phase
    })
    |> Map.put(:drawing_strokes, [])
  end

  # Word settings for a new game, from the room state snapshot the caller already
  # authorized against. Makes the AI call for AI rooms.
  defp fetch_room_game_settings(rs) do
    wc = rs.word_count || 1
    p = rs.prompt
    tone = rs.ai_tone || :fun
    total_rounds = length(rs.players) * (rs.round_multiplier || 1)
    ai_num_words = min(max(total_rounds * 3, 9), 60)

    {generated, status} =
      if rs.word_source == :ai and p != nil and p != "" do
        case Games.generate_ai_words(p, wc, %{num_words: ai_num_words, tone: to_string(tone)}) do
          {:ok, words} when is_list(words) ->
            unique_words = Enum.uniq(words)
            {unique_words, "AI generated #{length(unique_words)}/#{ai_num_words} words"}

          {:error, reason} ->
            {[], "AI failed: #{inspect(reason)} — falling back to local words"}

          _ ->
            {[], "AI returned unexpected response — falling back to local words"}
        end
      else
        {[], nil}
      end

    {wc, generated, status}
  end
end
