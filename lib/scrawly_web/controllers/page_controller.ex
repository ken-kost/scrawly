defmodule ScrawlyWeb.PageController do
  use ScrawlyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
