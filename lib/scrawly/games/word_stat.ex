defmodule Scrawly.Games.WordStat do
  @moduledoc """
  How one curated entry (priv/words/words.csv) has played, in the
  `word_stats` table: one row per entry, keyed by its text rather than by a
  `words` row's id, so the word sync (`Scrawly.Games.sync_words/0`, which
  deletes and re-inserts a renamed entry's row) never touches the numbers.

  `Scrawly.Games.WordStats` records them during play and reports on them.
  The counters only ever grow, by the `:record` upsert.
  """

  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Games,
    data_layer: AshPostgres.DataLayer

  @counters [
    :offered,
    :picked,
    :rounds,
    :guessers,
    :correct,
    :first_guess_ms_sum,
    :first_guess_rounds
  ]

  postgres do
    table "word_stats"
    repo Scrawly.Repo
  end

  actions do
    defaults [:read]

    # One INSERT ... ON CONFLICT per call (or per batch of rows): two rooms
    # recording the same entry at once both count.
    create :record do
      description """
      Adds the given counts to an entry's row: a first sighting inserts the
      row with them, otherwise each counter grows by its count atomically.
      """

      accept [:text | @counters]
      upsert? true
      # The counters are set by AddCounts' increments; the rest of the row
      # stays, but for its update time.
      upsert_fields [:updated_at]
      change Scrawly.Games.WordStat.Changes.AddCounts
    end
  end

  attributes do
    attribute :text, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    # Times shown among the drawer's choices.
    attribute :offered, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    # Times chosen, by the drawer or by the choice timer.
    attribute :picked, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    # Rounds played to the end (time up or everyone guessed) with it.
    attribute :rounds, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    # Players who could have guessed it, summed over those rounds.
    attribute :guessers, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    # Those of them who did.
    attribute :correct, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    # Ms from the start of the drawing to the first correct guess, summed
    # over the rounds that had one (first_guess_rounds).
    attribute :first_guess_ms_sum, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :first_guess_rounds, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    timestamps()
  end

  @doc "The counter attributes, in table order."
  @spec counters() :: [atom]
  def counters, do: @counters
end
