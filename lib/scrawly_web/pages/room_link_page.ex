defmodule ScrawlyWeb.Pages.RoomLinkPage do
  @moduledoc """
  The short room link `/r/:code`, which a lobby's "copy invite link" copies.

  It never renders: its middleware answers every request with a redirect
  (a 302 on a first load, Hologram's redirect payload on a client-side
  navigation), so the link never becomes a history entry of its own.

    * A room with this code (any case) that hasn't ended: its game page
      (`ScrawlyWeb.RoomCodes.entry_path/2`). A signed-out visitor goes
      through `/guest` first and arrives as a guest.
    * Anything else: Home, whose code field then says "no room with that
      code" (or "too many tries, wait a minute" past the lookup cap).

  A redirect has to come from middleware: Hologram 0.12 reads a status only
  after the middleware chain, so `put_redirect/2` in `init/3` would be
  ignored (GamePage's missing-room placeholder works around the same limit).
  """

  use ScrawlyWeb.Page, load: :id_only

  alias ScrawlyWeb.CommandParams
  alias ScrawlyWeb.Pages.HomePage
  alias ScrawlyWeb.RoomCodes

  route "/r/:code"
  param :code, :string

  middleware :open_room

  @doc false
  def open_room(server, _opts) do
    input = code_param(server)

    case RoomCodes.lookup(server, input) do
      {:ok, room_id} ->
        put_redirect(server, RoomCodes.entry_path(server, room_id))

      {:error, reason} ->
        server
        |> RoomCodes.put_notice(reason, input)
        |> put_redirect(HomePage)
    end
  end

  # Middleware gets no page params, so the code is read from the request: the
  # path of a first load ("/r/<code>"), or the query of a client-side
  # navigation's page request (`?code=<code>`). A valid code needs no
  # percent-decoding.
  defp code_param(%{path: "/r/" <> code}), do: code
  defp code_param(%{query: %{"code" => code}}) when is_binary(code), do: code
  defp code_param(_server), do: ""

  # Never shown (the middleware always redirects).
  def template do
    ~HOLO"""
    <div class="page page-mid">
      <div class="mono" style="font-size: 12px; color: var(--muted);">opening the room…</div>
    </div>
    """
  end

  def command(name, _params, server), do: CommandParams.deny_unknown(server, name)
end
