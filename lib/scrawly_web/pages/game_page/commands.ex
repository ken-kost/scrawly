defmodule ScrawlyWeb.Pages.GamePage.Commands do
  @moduledoc """
  Server-side command logic for GamePage.

  All functions here run exclusively on the server — never compiled to JS by Hologram.
  They receive a `%Hologram.Server{}` struct and return one (possibly with a next_action).

  The acting user always comes from the session via `ScrawlyWeb.Auth`, never from
  params. Rejected commands reply with `:command_denied` (see `Auth.deny/3`).

  Every `:room_refreshed` reply is the session user's own view of the room
  (`RoomServer.get_view/2`): the word and the word choices are only ever sent
  to the current drawer.
  """

  require Logger

  import Hologram.Component, only: [put_action: 2, put_action: 3, put_broadcast_except: 5]

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.{RoomServer, StrokeRules}
  alias Scrawly.Games.RoomServer.GameFlow
  alias ScrawlyWeb.Auth

  def poll_room_state(%{room_id: room_id}, server) do
    reply_with_view(server, room_id)
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

            reply_with_view(server, room_id)

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
          {:ok, _state} -> reply_with_view(server, room_id)
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
          reply_with_view(server, room_id)

        {:error, reason} ->
          Auth.deny(server, :start_game, reason)
      end
    else
      {:error, reason} -> Auth.deny(server, :start_game, reason)
    end
  end

  @doc """
  Commits `word` for the session user, who must be the current drawer while
  the room is `:choosing` and `word` one of their choices (checked by the room
  process). Replies with the drawer's view, or `:command_denied`.
  """
  def choose_word(%{room_id: room_id, word: word}, server) do
    with {:ok, uid} <- session_user_id(server),
         {:ok, _state} <- RoomServer.choose_word(room_id, uid, word) do
      reply_with_view(server, room_id)
    else
      {:error, reason} when is_atom(reason) -> Auth.deny(server, :choose_word, reason)
      {:error, _reason} -> Auth.deny(server, :choose_word, :choose_failed)
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

  @doc """
  Stores a completed stroke drawn by the session user and fans it out to the
  room's other tabs. Only `room_id`, `stroke_id`, `path`, `color`, `width`,
  `op_epoch` and `op_seq` are read from params.

  The room process checks that the session user is the current drawer while
  `:drawing` and validates the stroke (`StrokeRules`, including the stroke id).
  The three stroke commands are the drawer tab's op queue
  (drawing_manager.mjs): each carries `{op_epoch, op_seq}`
  (`StrokeRules.op_tag/2`) and is acknowledged with `:stroke_op_acked`
  (`op_seq`), whether it was applied or ignored as a duplicate (a stroke id the
  room already holds, or a resent op). Duplicates broadcast nothing.

  A non-drawer, the wrong phase, a missing room or no account gets
  `:command_denied` (with `op_seq`); an invalid stroke or a full canvas gets
  `:stroke_rejected` with the stored strokes, so the drawer's canvas drops
  what nobody else will see.
  """
  def complete_stroke(%{room_id: room_id} = params, server) do
    stroke = %{
      id: Map.get(params, :stroke_id),
      path: Map.get(params, :path),
      color: Map.get(params, :color),
      width: Map.get(params, :width)
    }

    with {:ok, uid} <- session_user_id(server),
         :ok <- RoomServer.append_drawing(room_id, uid, stroke, op_tag(params)) do
      server
      |> broadcast_to_other_tabs(room_id, :stroke_completed, stroke_completed(stroke))
      |> ack_stroke_op(params)
    else
      :duplicate ->
        ack_stroke_op(server, params)

      {:error, reason, strokes} ->
        Logger.warning(
          "stroke rejected: #{inspect(reason)} in room #{inspect(room_id)} " <>
            "for #{inspect(Auth.user_id(server))}"
        )

        put_action(server, :stroke_rejected,
          stroke_id: clean_stroke_id(stroke.id),
          reason: reason,
          strokes: strokes,
          op_seq: op_seq(params)
        )

      {:error, reason} ->
        deny_stroke_op(server, :complete_stroke, reason, params)
    end
  end

  @doc """
  Clears the canvas as the session user (current drawer, `:drawing` only).
  An op of the drawer's queue: see `complete_stroke/2`.
  """
  def clear_drawing_cmd(%{room_id: room_id} = params, server) do
    with {:ok, uid} <- session_user_id(server),
         :ok <- RoomServer.clear_drawing(room_id, uid, op_tag(params)) do
      server
      |> broadcast_to_other_tabs(room_id, :drawing_cleared, %{})
      |> ack_stroke_op(params)
    else
      :duplicate -> ack_stroke_op(server, params)
      {:error, reason} -> deny_stroke_op(server, :clear_drawing_cmd, reason, params)
    end
  end

  @doc """
  Removes the stroke `stroke_id` as the session user (current drawer,
  `:drawing` only) and broadcasts the remaining strokes. An unknown id changes
  nothing and broadcasts nothing. An op of the drawer's queue: see
  `complete_stroke/2`.
  """
  def undo_drawing_cmd(%{room_id: room_id} = params, server) do
    stroke_id = Map.get(params, :stroke_id)

    with {:ok, uid} <- session_user_id(server),
         {:ok, strokes} <- RoomServer.undo_drawing(room_id, uid, stroke_id, op_tag(params)) do
      server
      |> broadcast_to_other_tabs(room_id, :drawing_undone, %{strokes: strokes})
      |> ack_stroke_op(params)
    else
      :duplicate -> ack_stroke_op(server, params)
      {:error, reason} -> deny_stroke_op(server, :undo_drawing_cmd, reason, params)
    end
  end

  # Excludes only the tab that sent the command: it already shows the change.
  # Never exclude by {:user, id}: this app does not set Hologram's user id.
  defp broadcast_to_other_tabs(server, room_id, action, params) do
    put_broadcast_except(
      server,
      {:instance, server.instance_id},
      {:room, room_id},
      action,
      params
    )
  end

  # The stored stroke, with the id under the key viewers already use for the
  # live overlay.
  defp stroke_completed(stroke) do
    %{stroke_id: stroke.id, path: stroke.path, color: stroke.color, width: stroke.width}
  end

  defp op_tag(params),
    do: StrokeRules.op_tag(Map.get(params, :op_epoch), Map.get(params, :op_seq))

  defp op_seq(params) do
    case op_tag(params) do
      {_epoch, seq} -> seq
      nil -> nil
    end
  end

  defp ack_stroke_op(server, params),
    do: put_action(server, :stroke_op_acked, op_seq: op_seq(params))

  defp deny_stroke_op(server, command, reason, params) do
    case op_seq(params) do
      nil -> Auth.deny(server, command, reason)
      seq -> Auth.deny(server, command, reason, op_seq: seq)
    end
  end

  defp clean_stroke_id(id), do: if(StrokeRules.valid_stroke_id?(id), do: id, else: nil)

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

  # Strokes are stripped: the page keeps its own list (init, stroke actions).
  defp reply_with_view(server, room_id) do
    case RoomServer.get_view(room_id, Auth.user_id(server)) do
      {:ok, view} ->
        put_action(server, :room_refreshed, Map.put(view, :drawing_strokes, []))

      {:error, :not_found} ->
        put_action(server, :room_dissolved)
    end
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
