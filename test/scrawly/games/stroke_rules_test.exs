defmodule Scrawly.Games.StrokeRulesTest do
  use ExUnit.Case, async: true

  alias Scrawly.Games.StrokeRules

  @stroke %{path: "M 10 20 L 30.5 40.25", color: "#d63838", width: 5}

  describe "valid_color?/1" do
    test "accepts #RRGGBB in either case (palette, eraser, default)" do
      for color <- ["#0a0a0a", "#d63838", "#FFFFFF", "#000000", "#AbCdEf"] do
        assert StrokeRules.valid_color?(color), color
      end
    end

    test "rejects anything else" do
      for color <- [
            "red",
            "#fff",
            "#ggggggg",
            "#1234567",
            "000000",
            "#12345",
            "#12345g",
            "",
            nil,
            0
          ] do
        refute StrokeRules.valid_color?(color), inspect(color)
      end

      refute StrokeRules.valid_color?("#ffffff\n")
      refute StrokeRules.valid_color?("#ffffff\" onload=\"x")
    end
  end

  describe "valid_width?/1" do
    test "accepts integers in 1..40" do
      for width <- [1, 2, 5, 10, 20, 40], do: assert(StrokeRules.valid_width?(width))
    end

    test "rejects everything else" do
      for width <- [0, -1, 41, 1_000, 2.0, "2", nil] do
        refute StrokeRules.valid_width?(width), inspect(width)
      end
    end
  end

  describe "valid_path?/1" do
    test "accepts SVG path data, including curves, exponents and negatives" do
      for path <- [
            "M 1 2",
            "M 10 20 L 30.5 40.25 L -1 -2",
            "M1,2Q3,4,5,6C7 8 9 10 11 12Z",
            "m 1e-7 2E3 l 3 4 z"
          ] do
        assert StrokeRules.valid_path?(path), path
      end
    end

    test "rejects other characters, empty paths and non-binaries" do
      for path <- [
            "",
            "M 1 2 <script>",
            "M 1 2\" onload=\"alert(1)",
            "M 1 2\nL 3 4",
            "A 1 1 0 0 0 2 2",
            "M NaN undefined",
            nil,
            123,
            ["M 1 2"],
            %{path: "M 1 2"}
          ] do
        refute StrokeRules.valid_path?(path), inspect(path)
      end
    end

    test "caps a path at 64 KB" do
      max = StrokeRules.max_path_bytes()
      assert max == 65_536
      assert StrokeRules.valid_path?(String.duplicate("1", max))
      refute StrokeRules.valid_path?(String.duplicate("1", max + 1))
    end
  end

  describe "valid_delta?/1" do
    test "uses the path character set with a 2_000 byte cap" do
      assert StrokeRules.valid_delta?(" L 10 20")
      assert StrokeRules.valid_delta?(String.duplicate("1", 2_000))
      refute StrokeRules.valid_delta?(String.duplicate("1", 2_001))
      refute StrokeRules.valid_delta?("")
      refute StrokeRules.valid_delta?(" L 1 2 <b>")
      refute StrokeRules.valid_delta?(nil)
    end
  end

  describe "valid_stroke_id?/1" do
    test "is a binary of 1..64 bytes" do
      assert StrokeRules.valid_stroke_id?("s-1700000000000-1")
      assert StrokeRules.valid_stroke_id?(String.duplicate("a", 64))
      refute StrokeRules.valid_stroke_id?(String.duplicate("a", 65))
      refute StrokeRules.valid_stroke_id?("")
      refute StrokeRules.valid_stroke_id?(nil)
      refute StrokeRules.valid_stroke_id?(1)
    end
  end

  describe "check_append/2" do
    test "returns only path, color and width" do
      assert StrokeRules.check_append([], Map.merge(@stroke, %{stroke_id: "x", user_id: "y"})) ==
               {:ok, @stroke}
    end

    test "rejects a missing or invalid field" do
      for bad <- [
            Map.delete(@stroke, :path),
            Map.delete(@stroke, :color),
            Map.delete(@stroke, :width),
            %{@stroke | path: nil},
            %{@stroke | path: "M 1 2 <x>"},
            %{@stroke | color: "red"},
            %{@stroke | width: 41},
            "M 1 2",
            nil
          ] do
        assert StrokeRules.check_append([], bad) == {:error, :invalid_stroke}, inspect(bad)
      end
    end

    test "allows 500 strokes and rejects stroke 501" do
      max = StrokeRules.max_strokes()
      assert max == 500
      strokes = List.duplicate(@stroke, max - 1)

      assert {:ok, _} = StrokeRules.check_append(strokes, @stroke)
      assert StrokeRules.check_append([@stroke | strokes], @stroke) == {:error, :stroke_limit}
    end

    test "rejects a stroke that would push the canvas over 2_000_000 path bytes" do
      assert StrokeRules.max_canvas_bytes() == 2_000_000
      big = %{@stroke | path: String.duplicate("1", 50_000)}
      strokes = List.duplicate(big, 40)
      assert StrokeRules.canvas_bytes(strokes) == 2_000_000

      assert StrokeRules.check_append(strokes, %{@stroke | path: "1"}) == {:error, :stroke_limit}

      assert {:ok, _} =
               StrokeRules.check_append(Enum.drop(strokes, 1), %{
                 @stroke
                 | path: String.duplicate("1", 50_000)
               })
    end
  end
end
