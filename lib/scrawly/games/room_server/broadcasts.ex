defmodule Scrawly.Games.RoomServer.Broadcasts do
  @moduledoc """
  Everything a room pushes to game pages, on two Hologram Realtime channels:

    * `{:room, room_id}` - the public channel every GamePage (and the score
      page while `:post_game`) subscribes to. Every action on it goes through
      `publish/3`, which stamps it with the room's next `seq`, exactly one
      higher than the previous one. Pages use the seq to notice a lost
      broadcast (Realtime is at-most-once, with no replay) and resync. Never
      exclude a subscriber from a sequenced action (`*_except`): every
      subscriber must see every seq.
    * `{:room_player, room_id, user_id}` - one user's private channel. A page
      subscribes to its own session user's channel in `init/3` (the grant is
      made on the server and receipts are signed, so nobody can subscribe to
      another user's). The drawer's word choices and committed word go only
      here (`push_private_slice/1`), never on `{:room}`; they carry no seq.

  Only the room process calls these, so seqs are produced by one process and
  arrive in order; the seq exists to detect loss, not to fix ordering.

  A room also keeps the home page's room list current on the `:lobby`
  channel (`notify_lobby/1`), which `LobbyChatServer` shares for the lobby
  chat: `:lobby_room_changed` with the room's `View.lobby_summary/1` while it
  is in the lobby, `:lobby_room_removed` once it isn't (started, finished,
  dissolved, stopped). These carry no seq: each one replaces what the list
  holds for that room, so a lost one leaves that room stale until the next
  change or a page load.
  """

  alias Scrawly.Games.RoomServer.View

  @doc "The public channel of `room_id`."
  @spec room_channel(term) :: {:room, term}
  def room_channel(room_id), do: {:room, room_id}

  @doc "`user_id`'s private channel in `room_id`."
  @spec player_channel(term, term) :: {:room_player, term, term}
  def player_channel(room_id, user_id), do: {:room_player, room_id, user_id}

  @doc "The home page's channel: the room list and the lobby chat."
  @spec lobby_channel() :: :lobby
  def lobby_channel, do: :lobby

  @doc """
  Broadcasts `action` on the room's public channel with `params` plus the next
  `seq`, and returns the state holding that seq. The one place a `{:room}`
  broadcast is sent.
  """
  @spec publish(map, atom, map) :: map
  def publish(state, action, params) when is_atom(action) and is_map(params) do
    seq = state.seq + 1

    Hologram.Realtime.broadcast_action(
      room_channel(state.room_id),
      action,
      Map.put(params, :seq, seq)
    )

    %{state | seq: seq}
  end

  @doc """
  Sends the current drawer their private slice (`View.private_slice/1`) as
  `:private_state` on their own channel. Call it AFTER the public
  `:room_delta` of the same transition: the page applies a slice only once it
  knows the slice's round (an earlier one is ignored, a later one held until
  the delta for that round arrives). Returns the state unchanged; does
  nothing when there is no drawer or the drawer is no longer a player.
  """
  @spec push_private_slice(map) :: map
  def push_private_slice(%{current_drawer_id: drawer_id} = state) do
    if View.drawer?(state, drawer_id) do
      Hologram.Realtime.broadcast_action(
        player_channel(state.room_id, drawer_id),
        :private_state,
        View.private_slice(state)
      )
    end

    state
  end

  @doc """
  Tells the home pages about the room's current lobby status:
  `:lobby_room_changed` (`%{room: View.lobby_summary(state)}`) while it is
  listed (`listed?/1`), otherwise `:lobby_room_removed` (`%{room_id: id}`).
  Returns the state unchanged.
  """
  @spec notify_lobby(map) :: map
  def notify_lobby(state) do
    if listed?(state) do
      Hologram.Realtime.broadcast_action(lobby_channel(), :lobby_room_changed, %{
        room: View.lobby_summary(state)
      })
    else
      lobby_room_removed(state.room_id)
    end

    state
  end

  @doc """
  Whether the home pages list the room: it is in the lobby and its creator
  is one of its players (nobody else may join a room whose creator is
  absent).
  """
  @spec listed?(map) :: boolean
  def listed?(%{status: :lobby} = state),
    do: Enum.any?(state.players, &(&1.id == state.creator_id))

  def listed?(_state), do: false

  @doc """
  Scrawly.PubSub topic on which the room says that who may draw may have
  changed (`drawing_changed/1`). The GameChannel of each member subscribes,
  so its cached stroke-chunk verdict never outlives a phase, a turn or a
  membership.
  """
  @spec drawing_topic(term) :: String.t()
  def drawing_topic(room_id), do: "room_drawing:#{room_id}"

  @doc """
  Sends `{:drawing_changed, room_id}` on `drawing_topic/1`. The room calls
  it with every `:room_delta`: each phase, turn or membership change goes
  out as one.
  """
  @spec drawing_changed(term) :: :ok
  def drawing_changed(room_id) do
    Phoenix.PubSub.broadcast(Scrawly.PubSub, drawing_topic(room_id), {:drawing_changed, room_id})
  end

  @doc "Takes `room_id` off the home pages' room list (`:lobby_room_removed`)."
  @spec lobby_room_removed(term) :: :ok
  def lobby_room_removed(room_id) do
    Hologram.Realtime.broadcast_action(lobby_channel(), :lobby_room_removed, %{room_id: room_id})
    :ok
  end
end
