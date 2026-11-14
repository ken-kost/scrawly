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
  """

  alias Scrawly.Games.RoomServer.View

  @doc "The public channel of `room_id`."
  @spec room_channel(term) :: {:room, term}
  def room_channel(room_id), do: {:room, room_id}

  @doc "`user_id`'s private channel in `room_id`."
  @spec player_channel(term, term) :: {:room_player, term, term}
  def player_channel(room_id, user_id), do: {:room_player, room_id, user_id}

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
  nothing when there is no drawer.
  """
  @spec push_private_slice(map) :: map
  def push_private_slice(%{current_drawer_id: drawer_id} = state) when is_binary(drawer_id) do
    Hologram.Realtime.broadcast_action(
      player_channel(state.room_id, drawer_id),
      :private_state,
      View.private_slice(state)
    )

    state
  end

  def push_private_slice(state), do: state
end
