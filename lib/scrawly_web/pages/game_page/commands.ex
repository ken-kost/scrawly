defmodule ScrawlyWeb.Pages.GamePage.Commands do
  @moduledoc """
  Server-side command logic for GamePage.

  All functions here run exclusively on the server — never compiled to JS by Hologram.
  They receive a `%Hologram.Server{}` struct and return one (possibly with a next_action).

  The acting user always comes from the session via `ScrawlyWeb.Auth`, never from
  params. Rejected commands reply with `:command_denied` (see `Auth.deny/3`).

  The page is push-only: room changes reach it as sequenced broadcasts
  (`RoomServer.Broadcasts`). Only full snapshots carry a seq: the join replies
  and `resync_room/2` reply `:room_resynced` with the session user's own view
  of the room (`RoomServer.get_view/2`, chat and strokes included; the word
  and the word choices only for the current drawer). Other replies carry no
  seq, so they can never make the page drop a broadcast still on its way.
  """

  require Logger

  import Hologram.Component, only: [put_action: 2, put_action: 3, put_subscription: 2]

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.{AnswerKind, RoomServer, StrokeRules}
  alias Scrawly.Games.RoomServer.{Broadcasts, GameFlow}
  alias ScrawlyWeb.{Auth, CommandParams, RoomSettings, RoomSubscriptions, SocketToken}

  @doc """
  The shape check in front of every room command (GamePage.command/3; the
  score page's `leave_room` / `dissolve_room` too): params must be a map with
  a UUID `room_id`, plus a string `word` for `:choose_word`, a string `text`
  for `:submit_guess` and a map `settings` for `:update_room_settings`. The
  other fields stay optional and are validated where they are used
  (`StrokeRules`, `RoomSettings.to_attrs/2`, the room process).
  `:error` means deny (`CommandParams.deny_invalid/2`).
  """
  @spec valid_params(atom, term) :: {:ok, map} | :error
  def valid_params(command, params) do
    with {:ok, room_id} <- CommandParams.uuid(params, :room_id),
         :ok <- required_field(command, params) do
      {:ok, Map.put(params, :room_id, room_id)}
    end
  end

  defp required_field(:choose_word, params), do: present(CommandParams.string(params, :word))
  defp required_field(:submit_guess, params), do: present(CommandParams.string(params, :text))

  defp required_field(:update_room_settings, params),
    do: if(is_map(Map.get(params, :settings)), do: :ok, else: :error)

  defp required_field(_command, _params), do: :ok

  defp present(nil), do: :error
  defp present(_string), do: :ok

  @doc """
  Replies `:socket_token_refreshed` with a fresh socket token for the session
  (`""` without a valid session), for a page whose game socket was refused.
  """
  def refresh_socket_token(server),
    do: put_action(server, :socket_token_refreshed, token: SocketToken.mint(server) || "")

  @doc """
  Replies `:room_resynced` with the session user's snapshot of the room
  (`:room_dissolved` once it is gone). The page asks after a seq gap, when
  the drawer's private slice is missing, after a denied command and when a
  countdown stays at 0.

  With `resubscribe: true` (a page brought back by Back/Forward, which runs
  no init on the server) it also subscribes the page to the room's channels
  again, as `GamePage.init/3` does, and deletes the subscriptions the page
  shown before left behind: `:lobby` and the rooms in `stale_rooms`
  (`ScrawlyWeb.RoomSubscriptions`).
  """
  def resync_room(%{room_id: room_id} = params, server) do
    server =
      if Map.get(params, :resubscribe) == true do
        server
        |> RoomSubscriptions.drop_stale(params, keep_room: room_id)
        |> subscribe_to_room(room_id)
      else
        server
      end

    reply_with_snapshot(server, room_id)
  end

  @doc """
  The room's channels for the session user's page: the public `{:room}` one
  and, with an account, the user's own `{:room_player}` one (the drawer's
  private slice). Used by `GamePage.init/3` and `resync_room/2`.
  """
  def subscribe_to_room(server, room_id) do
    server = put_subscription(server, Broadcasts.room_channel(room_id))

    case Auth.user_id(server) do
      nil -> server
      uid -> put_subscription(server, Broadcasts.player_channel(room_id, uid))
    end
  end

  @doc """
  Joins `room_id` as a player for the session user: the room process first,
  then the DB membership (`Accounts.join_room`, which also starts the
  account's room score from 0, like the player's score in the room). Replies
  `:room_resynced`; a full room switches the page to watching; any other
  refusal (`:not_in_lobby`, `:creator_not_present`, `:not_found`) replies
  `:command_denied` with that reason.
  """
  def join_room(%{room_id: room_id}, server) do
    case Auth.current_user(server) do
      {:ok, user} ->
        player = %{
          id: user.id,
          username: user.username,
          score: 0,
          avatar_id: user.avatar_id || "a-mushroom",
          avatar_color: user.avatar_color || "3"
        }

        case RoomServer.join(room_id, player) do
          {:ok, _state} ->
            Accounts.join_room(user, room_id)
            Games.join_room(room_id, user.id)

            reply_with_snapshot(server, room_id)

          {:error, :room_full} ->
            put_action(server, :switch_to_watcher)

          {:error, reason} ->
            Auth.deny(server, :join_room, reason)
        end

      {:error, reason} ->
        Auth.deny(server, :join_room, reason)
    end
  end

  @doc """
  Watches `room_id` as the session's actor (`Auth.actor_key/1`: visitors
  without an account too). Replies `:room_resynced`; a full room or too many
  watch joins/leaves in a minute (`RoomServer.watch_rate_limit/0`) reply
  `:command_denied` with `:room_full` / `:rate_limited`.
  """
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
          {:ok, _state} ->
            reply_with_snapshot(server, room_id)

          {:error, reason} when reason in [:room_full, :rate_limited] ->
            Auth.deny(server, :join_as_watcher, reason)

          {:error, _} ->
            server
        end
    end
  end

  def leave_watcher(%{room_id: room_id}, server) do
    if key = Auth.actor_key(server), do: RoomServer.leave_watcher(room_id, key)
    put_action(server, :go_home)
  end

  @doc """
  Starts a game as the session user (the room's creator). Replies nothing on
  success: the caller's page is subscribed and gets the start as broadcasts
  (the drawer's choices on their private channel). Denials go through
  `Auth.deny/3`.
  """
  def start_game(%{room_id: room_id}, server) do
    with {:ok, uid} <- session_user_id(server),
         {:ok, state} <- RoomServer.get_state(room_id),
         :ok <- RoomServer.authorize(state, uid, :start_game) do
      # Only reached by an authorized creator: this may make an AI call.
      {answer_kind, ai_words, ai_status} = fetch_room_game_settings(state)

      {choices, remaining_ai, _used_from_ai} =
        GameFlow.pick_word_choices(ai_words, [], answer_kind, 3)

      case RoomServer.start_game(room_id, uid, %{word_choices: choices, ai_words: remaining_ai}) do
        {:ok, _state} ->
          if ai_status, do: RoomServer.system_message(room_id, ai_status)
          server

        {:error, reason} ->
          Auth.deny(server, :start_game, reason)
      end
    else
      {:error, reason} -> Auth.deny(server, :start_game, reason)
    end
  end

  @doc """
  Changes the room's settings as the session user, from the lobby's settings
  form: `settings` holds the form's values, parsed exactly as room creation
  parses them (`RoomSettings.to_attrs/2`, a blank name becoming the host's
  default name). The room process checks that the user is its creator and
  that it is in its lobby, and the Room validates the values
  (`RoomServer.update_settings/3`). Nothing else is read from params.

  Replies `:room_settings_saved` (the change itself reaches every page as a
  `:room_delta`), `:room_settings_failed` with a `field` (`:name`,
  `:prompt`, `:max_players`, or nil for the line above the form's buttons)
  and a `message` for values the room refuses, or `:command_denied` for
  anyone but the host, outside the lobby and for rooms that no longer exist.
  """
  def update_room_settings(%{room_id: room_id, settings: settings}, server) do
    case Auth.current_user(server) do
      {:ok, user} ->
        attrs = RoomSettings.to_attrs(settings, user.username)

        case RoomServer.update_settings(room_id, user.id, attrs) do
          {:ok, _state} ->
            put_action(server, :room_settings_saved)

          {:error, {:max_players_below, count}} ->
            put_action(server, :room_settings_failed,
              field: :max_players,
              message: RoomSettings.players_floor(count)
            )

          {:error, reason} when is_atom(reason) ->
            Auth.deny(server, :update_room_settings, reason)

          {:error, error} ->
            {field, message} = RoomSettings.failure(error, attrs, :update)
            put_action(server, :room_settings_failed, field: field, message: message)
        end

      {:error, reason} ->
        Auth.deny(server, :update_room_settings, reason)
    end
  end

  @doc """
  Commits `word` for the session user, who must be the current drawer while
  the room is `:choosing` and `word` the text of one of their choices
  (checked by the room process). Only the text is read: the round's
  difficulty is the room's own for that choice, whatever else the params
  hold. Replies `:private_state` with the drawer's slice (no seq), so the
  word shows at once, or `:command_denied`.
  """
  def choose_word(%{room_id: room_id, word: word}, server) do
    with {:ok, uid} <- session_user_id(server),
         {:ok, _state} <- RoomServer.choose_word(room_id, uid, word) do
      case RoomServer.get_private_slice(room_id, uid) do
        {:ok, slice} -> put_action(server, :private_state, slice)
        {:error, _} -> server
      end
    else
      {:error, reason} when is_atom(reason) -> Auth.deny(server, :choose_word, reason)
      {:error, _reason} -> Auth.deny(server, :choose_word, :choose_failed)
    end
  end

  @doc """
  Leaves `room_id` as the session user, then puts `done_action` (`:go_home` on
  GamePage, `:left_room` on GameScorePage). Shared by both pages.

  The creator leaving dissolves the room (the room process persists that
  before it stops). Leaving is idempotent: a user who is no longer in the
  RoomServer still gets their DB membership for this room cleared, without a
  denial. Visitors without an account just navigate.
  """
  def leave_room(%{room_id: room_id}, server, done_action \\ :go_home) do
    with {:ok, user} <- Auth.current_user(server) do
      case RoomServer.leave(room_id, user.id) do
        {:ok, :dissolved} ->
          :ok

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
  `done_action`. Anyone else is denied and nothing changes. The room process
  persists the dissolution before it stops; when the RoomServer is already
  gone, the DB room is dissolved here, only if its `creator_id` matches.
  """
  def dissolve_room(%{room_id: room_id}, server, done_action) do
    with {:ok, uid} <- session_user_id(server),
         :ok <- dissolve_room_server(room_id, uid) do
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

  Replies `:guess_result` with `outcome` (`:correct` also carries `points`,
  `:close` the sender's own `text`; the word itself never comes back here), or
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

          # The sender's own line, back to the sender alone.
          {:ok, {:close, text}} ->
            put_action(server, :guess_result, outcome: :close, text: text)

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
  Stores a completed stroke drawn by the session user; the room publishes it
  as `:stroke_completed` to every page (the drawer's own tabs ignore it).
  Only `room_id`, `stroke_id`, `path`, `color`, `width`, `op_epoch` and
  `op_seq` are read from params.

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
  what nobody else will see. The rejection echoes the commit's `game_id`
  and `round` (the page's turn when it sent the stroke), so the page can
  tell a late one from an earlier turn. An op over the drawer's rate limit
  (`StrokeRules.op_rate_limit/0`) gets no reply at all: the op stays at the
  head of the drawer's queue, which resends it after its retry delay, by
  when the window has room again, so nothing is lost.
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
      ack_stroke_op(server, params)
    else
      :duplicate ->
        ack_stroke_op(server, params)

      {:error, :rate_limited} ->
        server

      {:error, reason, strokes} ->
        Logger.warning(
          "stroke rejected: #{inspect(reason)} in room #{inspect(room_id)} " <>
            "for #{inspect(Auth.user_id(server))}"
        )

        put_action(server, :stroke_rejected,
          stroke_id: clean_stroke_id(stroke.id),
          reason: reason,
          strokes: strokes,
          op_seq: op_seq(params),
          game_id: CommandParams.string(params, :game_id),
          round: if(is_integer(Map.get(params, :round)), do: Map.get(params, :round))
        )

      {:error, reason} ->
        deny_stroke_op(server, :complete_stroke, reason, params)
    end
  end

  @doc """
  Clears the canvas as the session user (current drawer, `:drawing` only);
  the room publishes `:drawing_cleared`. An op of the drawer's queue: see
  `complete_stroke/2`.
  """
  def clear_drawing_cmd(%{room_id: room_id} = params, server) do
    with {:ok, uid} <- session_user_id(server),
         :ok <- RoomServer.clear_drawing(room_id, uid, op_tag(params)) do
      ack_stroke_op(server, params)
    else
      :duplicate -> ack_stroke_op(server, params)
      {:error, :rate_limited} -> server
      {:error, reason} -> deny_stroke_op(server, :clear_drawing_cmd, reason, params)
    end
  end

  @doc """
  Removes the stroke `stroke_id` as the session user (current drawer,
  `:drawing` only); the room publishes only that id as `:drawing_undone`.
  An unknown id changes nothing and publishes nothing. An op of the drawer's
  queue: see `complete_stroke/2`.
  """
  def undo_drawing_cmd(%{room_id: room_id} = params, server) do
    stroke_id = Map.get(params, :stroke_id)

    with {:ok, uid} <- session_user_id(server),
         :ok <- RoomServer.undo_drawing(room_id, uid, stroke_id, op_tag(params)) do
      ack_stroke_op(server, params)
    else
      :duplicate -> ack_stroke_op(server, params)
      {:error, :rate_limited} -> server
      {:error, reason} -> deny_stroke_op(server, :undo_drawing_cmd, reason, params)
    end
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
          {:ok, %{creator_id: ^uid}} ->
            Games.dissolve_room(room_id)
            :ok

          {:ok, _room} ->
            {:error, :not_creator}

          {:error, _} ->
            {:error, :not_found}
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

  # A full snapshot, built in one room call so its seq, chat and strokes
  # belong together: the only kind of reply that carries a seq. It also
  # carries a fresh socket token (a snapshot is what a reconnecting or newly
  # joined page acts on).
  defp reply_with_snapshot(server, room_id) do
    case RoomServer.get_view(room_id, Auth.user_id(server)) do
      {:ok, view} ->
        put_action(server, :room_resynced, Map.put(view, :socket_token, SocketToken.mint(server)))

      {:error, :not_found} ->
        put_action(server, :room_dissolved)
    end
  end

  # Word settings for a new game, from the room state snapshot the caller already
  # authorized against. Makes the AI call for AI rooms; its reply comes back
  # filtered for the answer kind (Scrawly.Games.AiWords). The status is the
  # one chat line players see about it, in plain words (ai_status/2); why a
  # call failed goes to the log only.
  defp fetch_room_game_settings(rs) do
    kind = AnswerKind.parse(rs.answer_kind)
    p = rs.prompt
    tone = rs.ai_tone || :fun
    total_rounds = RoomServer.total_rounds(length(rs.players), rs.round_multiplier || 1)
    ai_num_words = min(max(total_rounds * 3, 9), 60)

    {generated, status} =
      if rs.word_source == :ai and p != nil and p != "" do
        case generate_ai_words(p, kind, ai_num_words, tone) do
          {:ok, [_ | _] = words} ->
            {words, ai_status(kind, length(words))}

          other ->
            Logger.warning(
              "themed words unavailable for room #{Map.get(rs, :room_id)}: #{failure_tag(other)}"
            )

            {[], ai_status(kind, 0)}
        end
      else
        {[], nil}
      end

    {kind, generated, status}
  end

  # The model call can raise rather than return an error (a missing API key
  # raises inside Req): the game then starts with the built-in list instead
  # of failing the start command.
  defp generate_ai_words(prompt, kind, count, tone) do
    Games.generate_ai_words(prompt, kind, %{num_words: count, tone: to_string(tone)})
  rescue
    error -> {:raised, error}
  end

  # What went wrong, for the log: a reason atom or an error module, never the
  # error itself (Ash wraps the model request, prompt and credentials).
  defp failure_tag({:error, reason}) when is_atom(reason), do: inspect(reason)
  defp failure_tag({:error, %{__struct__: module}}), do: inspect(module)
  defp failure_tag({:raised, %{__struct__: module}}), do: "raised " <> inspect(module)
  defp failure_tag({:ok, []}), do: "no usable answers"
  defp failure_tag(_other), do: "unexpected reply"

  @doc """
  The chat line about a themed room's words, given how many the AI call
  brought: "words ready: 18 from your theme", or "couldn't get themed words,
  using the built-in list" when it brought none. "phrases" for a phrases
  room.
  """
  @spec ai_status(AnswerKind.t(), non_neg_integer) :: String.t()
  def ai_status(kind, 0), do: "couldn't get themed #{ai_noun(kind)}, using the built-in list"
  def ai_status(kind, count), do: "#{ai_noun(kind)} ready: #{count} from your theme"

  defp ai_noun(:phrases), do: "phrases"
  defp ai_noun(_kind), do: "words"
end
