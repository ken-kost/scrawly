defmodule ScrawlyWeb.Page do
  @moduledoc """
  Base for Scrawly's pages: `use Hologram.Page`, the session check
  (`ScrawlyWeb.Middleware.LoadCurrentUser`) and `ScrawlyWeb.Layouts.AppLayout`,
  whose `init/3` relies on that middleware's stash.

  Options are passed to `LoadCurrentUser` (e.g. `use ScrawlyWeb.Page, load:
  :id_only`). A page's own `middleware` lines run after the inherited one.
  """

  defmacro __using__(opts) do
    quote do
      use Hologram.Page

      middleware ScrawlyWeb.Middleware.LoadCurrentUser, unquote(opts)

      layout ScrawlyWeb.Layouts.AppLayout
    end
  end
end
