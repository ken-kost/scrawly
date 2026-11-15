defmodule Scrawly.Games.AnswerKind do
  @moduledoc """
  What a room's drawers choose from (the room's `answer_kind`).

  A **word** is a one-word answer ("lighthouse", "t-shirt"); a **phrase** is
  an answer of two or more words ("ice cream", "walk the dog"), as
  `Scrawly.Games.WordList.word_count/1` counts them. A room offers:

    * `:words` - only words;
    * `:phrases` - only phrases;
    * `:mixed` - words and phrases: every set of choices has exactly one
      phrase, the rest are words, in random order.

  `default/0` is the only place the default kind is set: the Room resource,
  the room process and the create form all read it.
  """

  @typedoc "A room setting."
  @type t :: :words | :phrases | :mixed

  @typedoc "The kind of one answer."
  @type answer :: :word | :phrase

  @kinds [:words, :phrases, :mixed]
  @default :mixed

  @doc "Every room setting, in the order the create form shows them."
  @spec all() :: [t]
  def all, do: @kinds

  @doc "The kind of a room created without one."
  @spec default() :: t
  def default, do: @default

  @doc """
  A room setting from untrusted input: one of `all/0`, as an atom or its
  name. Anything else (nil, a forged string, another atom) is `default/0`.

      iex> Scrawly.Games.AnswerKind.parse("phrases")
      :phrases
      iex> Scrawly.Games.AnswerKind.parse("Elixir.Kernel")
      :mixed
  """
  @spec parse(term) :: t
  def parse(kind) when kind in @kinds, do: kind

  def parse(kind) when is_binary(kind) do
    Enum.find(@kinds, @default, &(Atom.to_string(&1) == kind))
  end

  def parse(_kind), do: @default

  @doc """
  Whether `text` is a word or a phrase.

      iex> Scrawly.Games.AnswerKind.of("jack-o'-lantern")
      :word
      iex> Scrawly.Games.AnswerKind.of("walk the dog")
      :phrase
  """
  @spec of(String.t()) :: answer
  def of(text) when is_binary(text) do
    if Scrawly.Games.WordList.word_count(text) > 1, do: :phrase, else: :word
  end

  @doc "Whether a room of kind `kind` may offer `text`."
  @spec allows?(t, String.t()) :: boolean
  def allows?(:words, text), do: of(text) == :word
  def allows?(:phrases, text), do: of(text) == :phrase
  def allows?(:mixed, _text), do: true

  @doc """
  The kind of each of `count` choices for a room of kind `kind`, in the order
  they are shown: a random position for the phrase of a `:mixed` set.
  """
  @spec slots(t, non_neg_integer) :: [answer]
  def slots(:words, count), do: List.duplicate(:word, count)
  def slots(:phrases, count), do: List.duplicate(:phrase, count)
  def slots(:mixed, 0), do: []
  def slots(:mixed, count), do: Enum.shuffle([:phrase | List.duplicate(:word, count - 1)])
end
