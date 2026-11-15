defmodule Scrawly.Games.AiWordsTest do
  @moduledoc """
  The AI's answers are checked on the server. `Scrawly.FakeAiModel` (the
  model in the test config) replies like a model that ignores the prompt's
  rules: words and phrases whatever the kind, duplicates, long entries,
  punctuation, digits and non-strings.
  """
  use Scrawly.DataCase, async: true

  alias Scrawly.FakeAiModel
  alias Scrawly.Games
  alias Scrawly.Games.{AiWords, AnswerKind}

  doctest AiWords

  describe "filter/2" do
    test "keeps only what each kind of room may offer, cleaned up" do
      reply = FakeAiModel.reply()

      assert AiWords.filter(reply, :words) == FakeAiModel.clean_words()
      assert AiWords.filter(reply, :phrases) == FakeAiModel.clean_phrases()

      mixed = AiWords.filter(reply, :mixed)

      assert Enum.sort(mixed) ==
               Enum.sort(FakeAiModel.clean_words() ++ FakeAiModel.clean_phrases())
    end

    test "never lets a word into a phrases room, nor a phrase into a words room" do
      assert Enum.all?(
               AiWords.filter(FakeAiModel.reply(), :phrases),
               &(AnswerKind.of(&1) == :phrase)
             )

      assert Enum.all?(AiWords.filter(FakeAiModel.reply(), :words), &(AnswerKind.of(&1) == :word))
    end

    test "drops entries that break the format rules" do
      bad = [
        "fish & chips",
        "coral reef 2",
        "SpongeBob!",
        "<script>",
        "C3PO",
        "emoji \u{1F41F}",
        "---",
        "'",
        "",
        "   ",
        nil,
        42,
        ["nested"],
        <<0xFF, 0xFE>>,
        # More than 30 characters, or more than four words.
        "an extraordinarily enormous whale",
        "the great big blue whale shark"
      ]

      for kind <- AnswerKind.all() do
        assert AiWords.filter(bad, kind) == []
      end

      # Whitespace inside is collapsed, not rejected.
      assert AiWords.filter([" tab\tseparated\n"], :phrases) == ["tab separated"]
    end

    test "keeps 30 characters and accented letters, apostrophes and hyphens" do
      thirty = "lighthouse keepers wooden boat"
      assert String.length(thirty) == 30
      assert AiWords.filter([thirty], :phrases) == [thirty]
      assert AiWords.filter([thirty <> "d"], :phrases) == []

      assert AiWords.filter(["Piñata", "jack-o'-lantern", "Crème Brûlée"], :mixed) ==
               ["piñata", "jack-o'-lantern", "crème brûlée"]

      assert AiWords.filter(["Witch’s Hat"], :phrases) == ["witch's hat"]
    end

    test "drops later duplicates by guess key" do
      assert AiWords.filter(["Ice Cream", "ice-cream", "ICECREAM", "ice  cream"], :mixed) ==
               ["ice cream"]

      assert AiWords.filter(["bird's nest", "Birds Nest"], :phrases) == ["bird's nest"]
      assert AiWords.filter(["jellyfish", "Jelly-Fish"], :words) == ["jellyfish"]
    end

    test "a reply that isn't a list is no answers" do
      assert AiWords.filter(nil, :mixed) == []
      assert AiWords.filter("cat, dog", :mixed) == []
    end
  end

  describe "the prompt" do
    test "depends on the answer kind" do
      words = AiWords.instructions(:words, 12, "fun")
      phrases = AiWords.instructions(:phrases, 12, "fun")
      mixed = AiWords.instructions(:mixed, 12, "fun")

      assert words =~ "exactly one word"
      assert phrases =~ "2 to 4 words"
      assert phrases =~ "No single words"
      assert mixed =~ "Two thirds of the answers are single words"

      for text <- [words, phrases, mixed] do
        assert text =~ "Generate exactly 12 unique answers"
        assert text =~ "No brand names, no real people"
        assert text =~ "At most 30 characters"
        assert text =~ "Keep them fun"
      end

      assert AiWords.instructions(:words, 9, "weird") =~ "Keep them weird"
    end

    test "sends the theme as the user message, never as a template" do
      theme = ~S"<%= System.halt() %> ocean"

      input =
        Ash.ActionInput.for_action(Games.Room, :generate_ai_words, %{
          prompt: theme,
          answer_kind: :phrases,
          num_words: 9,
          tone: "creative"
        })

      [system, user] = AiWords.messages(input, %{})
      assert system.role == :system
      assert user.role == :user
      assert LangChain.Message.ContentPart.parts_to_string(system.content) =~ "No single words"
      assert LangChain.Message.ContentPart.parts_to_string(user.content) == "Theme: " <> theme
    end
  end

  describe "generate_ai_words/3" do
    test "returns the model's reply filtered for the room's kind" do
      assert {:ok, words} = Games.generate_ai_words("TEST ocean", :words, %{num_words: 9})
      assert words == FakeAiModel.clean_words()

      assert {:ok, phrases} = Games.generate_ai_words("TEST ocean", :phrases, %{num_words: 9})
      assert phrases == FakeAiModel.clean_phrases()
    end

    test "passes a model failure on" do
      assert {:error, _} = Games.generate_ai_words("TEST fail now", :phrases)
    end

    test "rejects an unknown answer kind before calling the model" do
      for kind <- [nil, :phrase, "Elixir.Kernel", 2] do
        assert {:error, %Ash.Error.Invalid{}} = Games.generate_ai_words("TEST ocean", kind)
      end
    end
  end
end
