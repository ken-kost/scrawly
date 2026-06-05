defmodule ScrawlyWeb.PageController do
  use ScrawlyWeb, :controller

  alias Hologram.Controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def show(conn, params) do
    case conn.private.plug_session["user_token"] do
      nil ->
        # No session — create a guest account and return to the requested page
        # so anyone with a room link can join and chat as a guest.
        conn
        |> redirect(to: "/guest?return_to=" <> URI.encode_www_form(conn.request_path))

      _user_token ->
        # User is authenticated, let Hologram handle the page routing
        Controller.handle_initial_page_request(conn, params)
    end
  end
end
