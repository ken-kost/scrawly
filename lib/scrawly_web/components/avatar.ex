defmodule ScrawlyWeb.Components.Avatar do
  @moduledoc """
  Renders a preset avatar as a colored tile referencing the
  shared `<defs>` rendered by `ScrawlyWeb.Components.AvatarDefs`.
  """
  use Hologram.Component

  prop :avatar_id, :string, default: "a-mushroom"
  prop :color, :string, default: "3"
  prop :size, :string, default: "md"
  prop :class, :string, default: ""

  def template do
    ~HOLO"""
    <span class={"avatar-tile avatar-size-" <> @size <> " " <> @class} data-c={@color}>
      <svg viewBox="0 0 100 100"><use href={"#" <> @avatar_id} /></svg>
    </span>
    """
  end
end
