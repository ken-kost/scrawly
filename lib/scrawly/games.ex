defmodule Scrawly.Games do
  use Ash.Domain,
    otp_app: :scrawly,
    extensions: [AshAdmin.Domain]

  require Ash.Query

  alias Scrawly.Games.{Word, WordList}

  admin do
    show? true
  end

  resources do
    resource Scrawly.Games.Room do
      # Room management code interfaces
      define :create_room, action: :create
      define :get_rooms, action: :read
      define :get_room_by_id, action: :read, get_by: [:id]
      define :get_room_by_code, action: :read, get_by: :code
      define :join_room, action: :join_room, args: [:player_id]
      define :auto_start_if_ready, action: :auto_start_if_ready
      define :handle_player_disconnect, action: :handle_player_disconnect, args: [:player_id]
      define :start_game, action: :start_game
      define :end_game, action: :end_game
      define :set_room_post_game, action: :post_game
      define :return_room_to_lobby, action: :return_to_lobby

      # AI word generation
      define :generate_ai_words, action: :generate_ai_words, args: [:prompt, :word_count]
    end

    resource Scrawly.Games.Game do
      # Game flow code interfaces
      define :create_game, action: :start_game, args: [:room_id, :total_rounds]
      define :get_game_by_id, action: :read, get_by: [:id]
      define :start_round, action: :start_round, args: [:current_drawer_id]
      define :select_next_drawer, action: :select_next_drawer, args: [:player_queue]
      define :next_round, action: :next_round
      define :complete_round, action: :complete_round
      define :end_current_game, action: :end_game
      define :cancel_game, action: :cancel
      define :get_in_progress_games_for_room, action: :in_progress_for_room, args: [:room_id]
      define :save_round_details, action: :save_round_details, args: [:round_details]
      define :get_games_for_room, action: :for_room, args: [:room_id]
    end

    resource Scrawly.Games.Word do
      # Word selection code interfaces
      define :create_word, action: :create
      define :get_all_words, action: :list_all
      define :get_words_by_difficulty, action: :list_by_difficulty, args: [:difficulty]

      define :get_words_by_difficulty_and_word_count,
        action: :list_by_difficulty_and_word_count,
        args: [:difficulty, :word_count]
    end

    resource Scrawly.Games.GameResult do
      define :create_game_result, action: :create
      define :get_game_results_for_player, action: :for_player, args: [:player_id]
      define :get_game_results_for_game, action: :for_game, args: [:game_id]
    end
  end

  # Save game results for all players when a game ends.
  def save_game_results(game_id, room_id, players, round_results \\ []) do
    Enum.each(players, fn player ->
      create_game_result(%{
        player_id: player.id,
        game_id: game_id,
        room_id: room_id,
        score: player.score || 0,
        player_username: player.username
      })
    end)

    # Save per-round breakdown to the Game record
    if round_results != [] do
      save_round_details(game_id, round_results)
    end
  end

  @doc """
  Dissolves a room in the DB: clears every member's room membership and
  marks the room `:ended`, so `RoomServer.ensure_started/1` never starts it
  again. The room process calls it before it stops (creator left, dissolved,
  creator gone after a game); commands call it only when no room process is
  running.
  """
  def dissolve_room(room_id) do
    with {:ok, room} <- get_room_by_id(room_id) do
      Enum.each(room.players, &Scrawly.Accounts.leave_room/1)
      end_game(room)
    end
  end

  @doc """
  Cancels every Game of `room_id` still `:in_progress` (a room process that
  restarted mid-game: nothing will ever finish them). Returns how many.
  """
  @spec cancel_interrupted_games(term) :: non_neg_integer
  def cancel_interrupted_games(room_id) do
    case get_in_progress_games_for_room(room_id) do
      {:ok, games} -> Enum.count(games, &match?({:ok, _}, cancel_game(&1)))
      {:error, _} -> 0
    end
  end

  @doc """
  A random word for a round, with optional difficulty weighting, word_count
  filter and exclusion.

  Options:
    * `:difficulty` - `:easy`, `:medium` or `:hard` (default: weighted random)
    * `:word_count` - 1, 2 or 3 (default: 1)
    * `:exclude` - words to avoid repeating; ignored when it would leave
      nothing to pick from

  When the database has no words for that difficulty and word count (e.g. an
  unseeded `words` table), it picks from the built-in list
  (`Scrawly.Games.Word.builtin_words/2`) instead, so a supported word count
  always yields a word.
  """
  def get_random_word(opts \\ []) do
    difficulty = Keyword.get(opts, :difficulty) || weighted_random_difficulty()
    exclude = Keyword.get(opts, :exclude, [])
    word_count = Keyword.get(opts, :word_count, 1)

    with {:ok, words} <- get_words_by_difficulty_and_word_count(difficulty, word_count) do
      texts =
        case Enum.map(words, & &1.text) do
          [] -> Word.builtin_words(word_count, difficulty)
          texts -> texts
        end

      available = Enum.reject(texts, &(&1 in exclude))
      pool = if available == [], do: texts, else: available

      case pool do
        [] ->
          {:error, "No words available for word_count=#{word_count}, difficulty=#{difficulty}"}

        _ ->
          {:ok, Enum.random(pool)}
      end
    end
  end

  @doc """
  Makes the `words` table match `Scrawly.Games.WordList`
  (priv/words/words.csv): inserts the entries it lacks, updates the
  difficulty and theme of the ones that differ, and deletes the rows no
  longer in the file. Entries match rows by text.

  Runs in one transaction and raises on failure, leaving the table as it
  was. A second run changes nothing. Called on every deploy
  (`Scrawly.Release.sync_words/0` from `bin/migrate`) and by
  priv/repo/seeds.exs.
  """
  @spec sync_words() :: %{
          inserted: non_neg_integer,
          updated: non_neg_integer,
          deleted: non_neg_integer
        }
  def sync_words do
    {:ok, counts} =
      Ash.transaction(Word, fn ->
        entries = Map.new(WordList.entries(), &{String.downcase(&1.text), &1})
        rows = get_all_words!()
        stored = MapSet.new(rows, & &1.text)

        missing = Enum.reject(entries, fn {text, _entry} -> text in stored end)
        {kept, gone} = Enum.split_with(rows, &Map.has_key?(entries, &1.text))

        changed =
          Enum.flat_map(kept, fn row ->
            entry = entries[row.text]

            if {row.difficulty, row.theme} == {entry.difficulty, entry.theme},
              do: [],
              else: [{row.id, Map.take(entry, [:difficulty, :theme])}]
          end)

        insert_words(Enum.map(missing, fn {_text, entry} -> entry end))
        update_words(changed)
        delete_words(Enum.map(gone, & &1.id))

        %{inserted: length(missing), updated: length(changed), deleted: length(gone)}
      end)

    counts
  end

  defp insert_words([]), do: :ok

  defp insert_words(entries) do
    Ash.bulk_create!(entries, Word, :create,
      return_errors?: true,
      stop_on_error?: true,
      return_records?: false
    )
  end

  # One UPDATE per distinct {difficulty, theme}.
  defp update_words(changed) do
    changed
    |> Enum.group_by(fn {_id, values} -> values end, fn {id, _values} -> id end)
    |> Enum.each(fn {values, ids} ->
      Word
      |> Ash.Query.filter(id in ^ids)
      |> Ash.bulk_update!(:update, values, strategy: :atomic, return_errors?: true)
    end)
  end

  defp delete_words([]), do: :ok

  defp delete_words(ids) do
    Word
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_destroy!(:destroy, %{}, strategy: :atomic, return_errors?: true)
  end

  def get_word_count do
    case get_all_words() do
      {:ok, words} -> length(words)
      _ -> 0
    end
  end

  defp weighted_random_difficulty do
    roll = :rand.uniform(100)

    cond do
      roll <= 30 -> :easy
      roll <= 80 -> :medium
      true -> :hard
    end
  end
end
