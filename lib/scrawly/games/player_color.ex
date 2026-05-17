defmodule Scrawly.Games.PlayerColor do
  @moduledoc """
  Deterministic color assignment for players so the same user shows the same
  hue across player lists, scoreboards, and avatar stacks.
  """

  @palette [
    "#c5f03a",
    "#7ad6ff",
    "#ff8a4d",
    "#ef5bff",
    "#9ee37d",
    "#ffd84a",
    "#2a6df4",
    "#ff5c2b"
  ]
  @palette_len 8

  @doc "Return a hex color for the given key (user id, username, etc.)."
  def for(nil), do: List.first(@palette)
  def for(""), do: List.first(@palette)

  def for(key) when is_binary(key) do
    idx = key |> String.to_charlist() |> Enum.sum() |> rem(@palette_len)
    Enum.at(@palette, idx)
  end

  def for(_), do: List.first(@palette)
end
