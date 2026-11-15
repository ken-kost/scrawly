defmodule Scrawly.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :scrawly

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Makes the `words` table match priv/words/words.csv
  (`Scrawly.Games.sync_words/0`) with only the Repo running, like
  `migrate/0`. `bin/migrate`, Fly's release command, runs it after the
  migrations, so every deploy syncs the words. Raises on failure (the
  deploy then stops).
  """
  def sync_words do
    load_app()

    {:ok, counts, _apps} =
      Ecto.Migrator.with_repo(Scrawly.Repo, fn _repo -> Scrawly.Games.sync_words() end)

    IO.puts(
      "words: #{counts.inserted} inserted, #{counts.updated} updated, #{counts.deleted} deleted"
    )

    counts
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
