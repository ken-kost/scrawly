defmodule ScrawlyWeb.Layouts.AppLayout do
  use Hologram.Component

  alias Hologram.UI.Runtime

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>Scrawly - Draw, Guess, Have Fun!</title>
        <link phx-track-static rel="stylesheet" href="/assets/css/app.css" />
        <Runtime />
      </head>
      <body class="bg-gray-50 text-black">
        <div id="hologram-page">
          <slot />
        </div>
      </body>
    </html>
    """
  end
end
