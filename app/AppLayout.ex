defmodule Scrawly.AppLayout do
  use Hologram.Component

  alias Hologram.UI.Runtime

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html>
      <head>
        <title>Scrawly - Draw, Guess, Have Fun!</title>
        <Runtime />
      </head>
      <body class="bg-gray-50 text-black">
        <slot />
      </body>
    </html>
    """
  end
end
