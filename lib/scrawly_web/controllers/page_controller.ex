defmodule ScrawlyWeb.PageController do
  use ScrawlyWeb, :controller
  
  alias Hologram.Controller

  def home(conn, _params) do
    render(conn, :home)
  end
  
  def show(conn, params) do
    # Let Hologram handle the page routing
    Controller.handle_initial_page_request(conn, params)
  end
end
