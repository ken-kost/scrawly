defmodule ScrawlyWeb.JsUnitTest do
  @moduledoc """
  Runs the JavaScript unit tests in test/js/ (`node --test`), e.g. the stroke
  engine's geometry, as part of `mix test`. Skipped when `node` is not on the
  PATH.
  """
  use ExUnit.Case, async: true

  @js_dir Path.expand("../js", __DIR__)
  @node System.find_executable("node")

  if @node == nil, do: @moduletag(skip: "node is not installed")

  test "node --test test/js/*.test.mjs passes" do
    files = Path.wildcard(Path.join(@js_dir, "*.test.mjs"))
    assert files != []

    {output, status} = System.cmd(@node, ["--test" | files], stderr_to_stdout: true)

    assert status == 0, output
  end
end
