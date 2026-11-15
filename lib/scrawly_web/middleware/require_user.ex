defmodule ScrawlyWeb.Middleware.RequireUser do
  @moduledoc """
  Gate for pages that need a signed-in user. Attach it after
  `ScrawlyWeb.Middleware.LoadCurrentUser` in its default `load: :user` mode,
  whose stashed `:current_user` it reads.

  Without a user it redirects to the home page: a 302 on a first load, page
  data for a client-side navigation. It gates the page's commands too (their
  reply is then a non-OK response).
  """

  use Hologram.Middleware

  alias Scrawly.Accounts.User

  @impl Hologram.Middleware
  def call(server, _opts) do
    case get_stash(server, :current_user) do
      %User{} -> server
      _nil -> put_redirect(server, ScrawlyWeb.Pages.HomePage)
    end
  end
end
