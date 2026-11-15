defmodule Scrawly.Games.Word do
  @moduledoc """
  A drawing word in the `words` table. `Scrawly.Games.sync_words/0` keeps the
  table equal to `Scrawly.Games.WordList` (priv/words/words.csv); rounds pick
  their words from here.
  """

  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Games,
    data_layer: AshPostgres.DataLayer

  alias Scrawly.Games.WordList

  postgres do
    table "words"
    repo Scrawly.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:text, :difficulty, :theme]
      change Scrawly.Games.Word.Changes.NormalizeText
    end

    update :update do
      primary? true
      accept [:difficulty, :theme]
    end

    read :list_all do
    end

    read :list_by_difficulty do
      argument :difficulty, :atom do
        allow_nil? false
        constraints one_of: WordList.difficulties()
      end

      filter expr(difficulty == ^arg(:difficulty))
    end

    read :list_by_difficulty_and_word_count do
      argument :difficulty, :atom do
        allow_nil? false
        constraints one_of: WordList.difficulties()
      end

      argument :word_count, :integer do
        allow_nil? false
        constraints min: 1, max: 4
      end

      filter expr(difficulty == ^arg(:difficulty) and word_count == ^arg(:word_count))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :text, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60
    end

    attribute :difficulty, :atom do
      allow_nil? false
      default :medium
      public? true
      constraints one_of: WordList.difficulties()
    end

    # Set from the text (Changes.NormalizeText), never supplied. Phrases have
    # 2 to 4 words (priv/words/README.md).
    attribute :word_count, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1, max: 4
    end

    attribute :theme, :atom do
      public? true
      constraints one_of: WordList.themes()
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    # Text is stored lowercase (Changes.NormalizeText), so this ignores case.
    identity :unique_text, [:text]
  end

  @doc """
  The words of `Scrawly.Games.WordList` with `word_count` words (and
  `difficulty`, when given): what `Scrawly.Games.get_random_word/1` falls back
  to when the `words` table has none, so word choices never run out.
  """
  @spec builtin_words(pos_integer, atom | nil) :: [String.t()]
  def builtin_words(word_count, difficulty \\ nil) do
    for entry <- WordList.entries(),
        difficulty in [nil, entry.difficulty],
        WordList.word_count(entry.text) == word_count,
        do: entry.text
  end
end
