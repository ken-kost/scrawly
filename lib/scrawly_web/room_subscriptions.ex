defmodule ScrawlyWeb.RoomSubscriptions do
  @moduledoc """
  Drops the Realtime subscriptions a page restored by Back/Forward does not
  want. Server-only.

  A restore runs no init on the server, so the tab's server-side bindings
  for cid "page" are still those of the page it showed before (Hologram
  replaces them only when it renders a page): e.g. GamePage's room channels
  under a restored HomePage, or HomePage's `:lobby` under a restored game
  page. Each page's restore command (HomePage `:resync_lobby`, GamePage
  `:resync_room` with `resubscribe: true`, GameScorePage `:resync_countdown`,
  ProfilePage / PastGamesPage `:drop_stale_subscriptions`) deletes them here.
  Which rooms that can be the tab knows (room_channels.mjs, `stale_rooms` in
  the params); deleting a channel the tab is not bound to is a no-op.

  Every page also has explicit no-op clauses for the other pages' broadcast
  actions, for what arrives before the delete lands.
  """

  import Hologram.Component, only: [delete_subscription: 2]

  alias Scrawly.Games.RoomServer.Broadcasts
  alias ScrawlyWeb.{Auth, CommandParams}

  # room_channels.mjs keeps at most this many room ids per tab.
  @max_rooms 20

  @doc """
  Deletes the subscriptions to the rooms listed in `params.stale_rooms`
  (their public channel and the session user's private one), except
  `keep_room`, and to `:lobby` unless `keep_lobby?`.
  """
  @spec drop_stale(Hologram.Server.t(), term, keyword) :: Hologram.Server.t()
  def drop_stale(server, params, opts \\ []) do
    keep_room = Keyword.get(opts, :keep_room)
    uid = Auth.user_id(server)

    server =
      params
      |> CommandParams.uuids(:stale_rooms, @max_rooms)
      |> Enum.reject(&(&1 == keep_room))
      |> Enum.reduce(server, fn room_id, server ->
        server = delete_subscription(server, Broadcasts.room_channel(room_id))

        if uid,
          do: delete_subscription(server, Broadcasts.player_channel(room_id, uid)),
          else: server
      end)

    if Keyword.get(opts, :keep_lobby?, false),
      do: server,
      else: delete_subscription(server, Broadcasts.lobby_channel())
  end
end
