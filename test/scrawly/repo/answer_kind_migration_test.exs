defmodule Scrawly.Repo.AnswerKindMigrationTest do
  @moduledoc """
  The migration that replaced rooms' `word_count` with `answer_kind`, run
  down and up again inside the test's sandbox transaction (Postgres DDL is
  transactional, so the rollback at the end undoes it).

  Its `down/0` and `up/0` run through `Ecto.Migration.Runner` in the test
  process: `Ecto.Migrator` would run them in a task while it holds the
  sandbox's one connection for its lock.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  alias Scrawly.Games
  alias Scrawly.Games.{AnswerKind, RoomServer}
  alias Scrawly.Repo

  @moduletag :capture_log

  @version 20_261_115_083_959
  @path Path.expand(
          "../../../priv/repo/migrations/20261115083959_replace_word_count_with_answer_kind.exs",
          __DIR__
        )

  setup_all do
    migration =
      case Code.ensure_loaded(Scrawly.Repo.Migrations.ReplaceWordCountWithAnswerKind) do
        {:module, module} -> module
        {:error, _} -> @path |> Code.compile_file() |> Enum.map(&elem(&1, 0)) |> hd()
      end

    %{migration: migration}
  end

  defp migrate(migration, operation) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      migration,
      :forward,
      operation,
      operation,
      log: false
    )
  end

  defp insert_old_room!(creator, name, word_count) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO rooms (name, creator_id, word_count) VALUES ($1, $2, $3) RETURNING id",
        [name, Ecto.UUID.dump!(creator.id), word_count]
      )

    Ecto.UUID.load!(id)
  end

  defp column_kinds do
    Repo.query!("SELECT name, answer_kind FROM rooms WHERE name LIKE 'TEST wc%' ORDER BY name").rows
  end

  test "one word per answer becomes words, two or three become phrases", %{migration: migration} do
    creator = create_user()
    mixed = Games.create_room!(%{name: "TEST wc mixed", creator_id: creator.id})

    migrate(migration, :down)

    # `down` maps phrases back to 2, words and mixed to 1.
    assert Repo.query!("SELECT word_count FROM rooms WHERE name = 'TEST wc mixed'").rows == [[1]]

    ids =
      for word_count <- [1, 2, 3],
          do: insert_old_room!(creator, "TEST wc#{word_count}", word_count)

    migrate(migration, :up)

    assert column_kinds() == [
             ["TEST wc mixed", "words"],
             ["TEST wc1", "words"],
             ["TEST wc2", "phrases"],
             ["TEST wc3", "phrases"]
           ]

    refute "word_count" in Repo.query!("SELECT * FROM rooms LIMIT 0").columns

    # The resource reads them back.
    assert Enum.map(ids, &Games.get_room_by_id!(&1).answer_kind) == [:words, :phrases, :phrases]
    assert Games.get_room_by_id!(mixed.id).answer_kind == :words
  end

  test "a room created before the migration still opens and plays", %{migration: migration} do
    Games.sync_words()
    creator = create_user()
    player = create_user()

    migrate(migration, :down)
    room_id = insert_old_room!(creator, "TEST wc2 old", 2)
    migrate(migration, :up)

    room = Games.get_room_by_id!(room_id)
    Scrawly.Accounts.join_room!(creator, room.id)
    Games.join_room!(room.id, creator.id)
    Scrawly.Accounts.join_room!(player, room.id)
    Games.join_room!(room.id, player.id)

    {:ok, _pid} = RoomServer.ensure_started(room.id)
    on_exit(fn -> stop_room(room.id) end)

    assert {:ok, %{answer_kind: :phrases, current_drawer_id: drawer}} =
             RoomServer.start_game(room.id, creator.id)

    assert {:ok, %{word_choices: choices}} = RoomServer.get_view(room.id, drawer)
    assert length(choices) == 3
    assert Enum.all?(choices, &(AnswerKind.of(&1.text) == :phrase))
  end
end
