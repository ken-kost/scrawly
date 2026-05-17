defmodule ScrawlyWeb.Components.NavbarPainter do
  @moduledoc """
  Stateless component that renders colored strokes in the navbar background.
  Animation state is managed by the parent AppLayout.
  """
  use Hologram.Component

  prop :strokes, :list, default: []

  def template do
    ~HOLO"""
    <div class="absolute inset-0 pointer-events-none overflow-hidden" style="z-index:0">
      {%for stroke <- @strokes}
        <div class="absolute left-0 transition-[width] duration-100 ease-linear" style={"bottom:" <> to_string(stroke.y) <> "px;height:14px;width:" <> to_string(stroke.progress) <> "%;background:" <> stroke.color <> ";opacity:0.35"}></div>
      {/for}
    </div>
    """
  end
end
