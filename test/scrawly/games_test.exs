defmodule Scrawly.GamesTest do
  use ExUnit.Case, async: true

  describe "Games domain" do
    test "domain exists and is properly configured" do
      # This test will fail until we create the Games domain
      assert Code.ensure_loaded?(Scrawly.Games)

      # Verify domain has the expected resources
      resources = Scrawly.Games |> Ash.Domain.Info.resources()
      resource_names = Enum.map(resources, &(Module.split(&1) |> List.last()))

      assert "Room" in resource_names
      assert "Game" in resource_names
    end
  end
end
