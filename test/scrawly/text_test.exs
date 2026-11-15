defmodule Scrawly.TextTest do
  @moduledoc "Caps for user-typed text: characters AND bytes, at grapheme boundaries (QA G2)."
  use ExUnit.Case, async: true

  alias Scrawly.Text

  # One grapheme of 1 + 2n bytes.
  defp heavy(n), do: "a" <> String.duplicate("́", n)

  describe "truncate/3" do
    test "keeps the longest grapheme prefix within both caps" do
      assert Text.truncate("hello", 3, 100) == "hel"
      assert Text.truncate("hello", 100, 3) == "hel"
      assert Text.truncate("héllo", 100, 2) == "h"
      assert Text.truncate(String.duplicate(heavy(2), 4), 10, 11) == String.duplicate(heavy(2), 2)
      assert Text.truncate("", 5, 5) == ""
    end

    test "never splits a grapheme: one over the byte cap leaves nothing" do
      assert Text.truncate(heavy(10), 1, 20) == ""
      assert Text.truncate("ab" <> heavy(10), 5, 20) == "ab"
    end
  end

  describe "clean/3" do
    test "trims, cuts, and trims what the cut left" do
      assert Text.clean("  hi there  ", 100, 100) == "hi there"
      assert Text.clean("hi there", 3, 100) == "hi"
      assert Text.clean("   ", 10, 10) == ""
    end

    test "is empty for non-strings and invalid UTF-8" do
      for bad <- [nil, 42, %{}, <<0xFF, 0xFE>>, "ok" <> <<0xC3>>] do
        assert Text.clean(bad, 10, 10) == ""
      end
    end
  end
end
