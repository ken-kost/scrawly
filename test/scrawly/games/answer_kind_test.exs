defmodule Scrawly.Games.AnswerKindTest do
  use ExUnit.Case, async: true

  alias Scrawly.Games.AnswerKind

  doctest AnswerKind

  test "the default is mixed, and it is one of the kinds" do
    assert AnswerKind.default() == :mixed
    assert AnswerKind.all() == [:words, :phrases, :mixed]
  end

  test "parse/1 keeps a known kind and turns anything else into the default" do
    for kind <- AnswerKind.all() do
      assert AnswerKind.parse(kind) == kind
      assert AnswerKind.parse(Atom.to_string(kind)) == kind
    end

    for forged <- [nil, "", "Words", "phrase", "1", "2", "Elixir.Kernel", :phrase, 2, %{}, []] do
      assert AnswerKind.parse(forged) == :mixed
    end
  end

  test "of/1: one word (hyphens included) is a word, more is a phrase" do
    for word <- ["cat", "t-shirt", "jack-o'-lantern", "  lighthouse "] do
      assert AnswerKind.of(word) == :word
    end

    for phrase <- ["ice cream", "bird's nest", "walk the dog", "butterflies in the stomach"] do
      assert AnswerKind.of(phrase) == :phrase
    end
  end

  test "allows?/2" do
    assert AnswerKind.allows?(:words, "cat")
    refute AnswerKind.allows?(:words, "ice cream")
    assert AnswerKind.allows?(:phrases, "ice cream")
    refute AnswerKind.allows?(:phrases, "cat")
    assert AnswerKind.allows?(:mixed, "cat")
    assert AnswerKind.allows?(:mixed, "ice cream")
  end

  test "slots/2: a mixed set has one phrase, at every position over time" do
    assert AnswerKind.slots(:words, 3) == [:word, :word, :word]
    assert AnswerKind.slots(:phrases, 3) == [:phrase, :phrase, :phrase]
    assert AnswerKind.slots(:mixed, 0) == []

    positions =
      for _ <- 1..200 do
        slots = AnswerKind.slots(:mixed, 3)
        assert Enum.sort(slots) == [:phrase, :word, :word]
        Enum.find_index(slots, &(&1 == :phrase))
      end

    assert Enum.sort(Enum.uniq(positions)) == [0, 1, 2]
  end
end
