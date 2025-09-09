defmodule ScrawlyWeb.PageController do
  use ScrawlyWeb, :controller

  alias Hologram.Controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def show(conn, params) do
    case conn.private.plug_session["user_token"] do
      nil ->
        # Store the return path and redirect to register
        conn
        |> put_session(:return_to, conn.request_path)
        |> redirect(to: "/register")

      _user_token ->
        # User is authenticated, let Hologram handle the page routing
        Controller.handle_initial_page_request(conn, params)
    end
  end
end
