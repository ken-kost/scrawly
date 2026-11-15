defmodule Mix.Tasks.Scrawly.WordReport do
  @shortdoc "Prints the words that play too hard, too easy or are rarely picked (CSV)"

  @moduledoc """
  Prints the word stats report, `Scrawly.Games.WordStats.report/1`, as CSV
  on standard output:

      mix scrawly.word_report > word_report.csv

  Only the Repo is started (`Scrawly.Release.word_report/1`), so it runs
  next to a running dev server, and the report reads in a read-only
  transaction. On an empty `word_stats` table it prints the header alone.

  Mix isn't part of a release: there, run
  `bin/scrawly eval "Scrawly.Release.word_report()"` (see
  priv/words/README.md).
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    # Ecto logs every query at :debug in dev, on the same standard output.
    Logger.configure(level: :warning)
    Scrawly.Release.word_report()
  end
end
