defmodule Scrawly.Games.AiWords do
  @moduledoc """
  Answers from the AI: the Room's `:generate_ai_words` action
  (`Scrawly.Games.generate_ai_words/3`) runs here.

  The prompt depends on the room's `Scrawly.Games.AnswerKind`, and every
  reply goes through `filter/2` before anything can use it: models ignore
  rules, so nothing they return reaches a game unchecked.

  The model is OpenAI's, unless `config :scrawly, Scrawly.Games.AiWords,
  model: Module` names a module with `ask(input, context)` (returning
  `{:ok, [String.t()]}` or `{:error, reason}`) to call instead. The test
  config does, so no test reaches OpenAI.
  """

  use Ash.Resource.Actions.Implementation

  alias Scrawly.Games.{AnswerKind, Guess, WordList}

  @max_length 30
  @max_phrase_words 4

  @impl true
  def run(input, _opts, context) do
    with {:ok, reply} <- model().ask(input, context) do
      {:ok, filter(reply, input.arguments.answer_kind)}
    end
  end

  @doc false
  # The real model call (see the moduledoc for the test stand-in).
  def ask(input, context) do
    AshAi.Actions.Prompt.run(
      input,
      [llm: LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"}), prompt: &messages/2],
      context
    )
  end

  defp model, do: Application.get_env(:scrawly, __MODULE__, [])[:model] || __MODULE__

  @doc false
  # Plain messages, so AshAi sends them as they are (it evaluates string
  # prompts as EEx templates, which must never see the player's theme).
  def messages(input, _context) do
    args = input.arguments

    [
      LangChain.Message.new_system!(instructions(args.answer_kind, args.num_words, args.tone)),
      LangChain.Message.new_user!("Theme: #{args.prompt}")
    ]
  end

  @doc """
  The instructions for `count` answers of `kind` in the given tone. The
  user's theme is sent apart from them, as the user message.
  """
  @spec instructions(AnswerKind.t(), pos_integer, String.t()) :: String.t()
  def instructions(kind, count, tone) do
    """
    You write answers for a drawing game: one player draws an answer, the others guess it.
    Generate exactly #{count} unique answers based on the theme the user gives.

    RULES:
    #{kind_rule(kind)}
    - Every answer names something concrete and easy to draw. No brand names, no real people.
    - Only letters, spaces, hyphens and apostrophes. At most #{@max_length} characters.
    - Keep them #{tone}.
    - No duplicates. Every answer must be unique.
    - Return exactly #{count} answers, no more, no less.
    """
  end

  defp kind_rule(:words) do
    ~s(- Every answer is exactly one word, like "lighthouse" or "t-shirt". No phrases, no spaces.)
  end

  defp kind_rule(:phrases) do
    """
    - Every answer is a real, well-known phrase or two-word thing of 2 to 4 words, \
    written naturally with its articles, like "ice cream", "walk the dog" or \
    "jack in the box". No single words.\
    """
  end

  defp kind_rule(:mixed) do
    """
    - Two thirds of the answers are single words, like "lighthouse". The other third \
    are real, well-known phrases of 2 to 4 words, written naturally with their \
    articles, like "walk the dog".\
    """
  end

  @doc """
  The entries of an AI reply a room of kind `kind` may use, cleaned up:
  trimmed, lowercase, single-spaced, typographic apostrophes made straight.

  Drops anything that is not a string, of the wrong kind (a word in a
  `:phrases` room, a phrase in a `:words` room, more than
  #{@max_phrase_words} words anywhere), longer than #{@max_length}
  characters, or with characters other than letters, spaces, hyphens and
  apostrophes, and every later duplicate by `Scrawly.Games.Guess.key/1`.

  In a `:mixed` room words and phrases both stay, and
  `Scrawly.Games.RoomServer.GameFlow.pick_word_choices/5` takes the phrase of
  every set apart from the words.

      iex> Scrawly.Games.AiWords.filter(["Sea Turtle", "octopus", "Sea-turtle", "fish & chips"], :phrases)
      ["sea turtle"]
  """
  @spec filter(term, AnswerKind.t()) :: [String.t()]
  def filter(reply, kind) when is_list(reply) do
    reply
    |> Enum.flat_map(&clean/1)
    |> Enum.filter(&fits?(&1, kind))
    |> Enum.uniq_by(&Guess.key/1)
  end

  def filter(_reply, _kind), do: []

  defp clean(text) when is_binary(text) do
    if String.valid?(text) do
      [
        text
        |> String.normalize(:nfc)
        |> String.replace(["’", "‘"], "'")
        |> String.split()
        |> Enum.join(" ")
        |> String.downcase()
      ]
    else
      []
    end
  end

  defp clean(_not_text), do: []

  defp fits?(text, kind) do
    String.length(text) <= @max_length and
      Regex.match?(~r/\A[\p{L}' -]+\z/u, text) and
      Guess.key(text) != "" and
      WordList.word_count(text) <= @max_phrase_words and
      AnswerKind.allows?(kind, text)
  end
end
