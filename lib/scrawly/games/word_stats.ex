defmodule Scrawly.Games.WordStats do
  @moduledoc """
  Play stats for the curated words (priv/words/words.csv), so their
  difficulty labels can be checked against how they really play
  (`report/1`). One `Scrawly.Games.WordStat` row per entry, keyed by its
  text: the word sync never touches them, and an entry renamed in the file
  starts again from zero.

  ## What is recorded, and when

  The room process calls these at three moments:

    * `offered/1`: a set of choices is shown to the drawer. `offered` +1
      for each.
    * `picked/2`: the drawer chooses one, or the choice timer picks one for
      them. `picked` +1.
    * `round_played/1`: a round ends because time is up or everyone
      guessed. `rounds` +1, the round's `guessers` and `correct` added, and,
      when someone guessed, the ms from the start of the drawing to the
      first correct guess (`first_guess_ms_sum`, `first_guess_rounds` +1).

  A round that ends early because the drawer left is not recorded (its
  `offered` and `picked` counts stay), and neither is one cut short by the
  game's end (fewer than 2 players left, the room dissolved).

  The guessers are the players other than the drawer at the round's end
  who were in the room when the turn began (`round_start_scores`); the
  correct ones are those of them who guessed. A player who left during the
  round counts in neither, even after guessing, and nor does their guess
  time. Players can't join a game in progress (joins are lobby-only and
  watchers can't guess), so nobody joins mid-round today; if that changes, a
  late joiner, who had less time, stays out of both numbers.

  Only curated entries are recorded:

    * only in rooms that play the built-in list (`word_source: :local`). An
      AI room records nothing, even when it falls back to the list: its
      sets can mix AI answers with curated entries, so its picks don't
      compare;
    * only choices that came from the list. A choice carries its origin: a
      curated entry has its difficulty, an AI answer has none
      (`t:Scrawly.Games.RoomServer.GameFlow.choice/0`), so an AI answer whose
      text happens to be on the list never counts;
    * only texts that are entries of the file (`WordList.entry/1`), so a
      stale `words` row never gets a stats row.

  ## Never in the round's way

  The counts are built in the room process from its state, with no I/O, and
  written in a task under `Scrawly.TaskSupervisor`: one upsert per moment
  (`Scrawly.Games.record_word_stats/2`) that inserts a first sighting and
  otherwise increments each counter in the database, so two rooms recording
  the same entry both count. A failed write is logged with its reason (the
  error's type, never the texts or counts) and dropped.

  `config :scrawly, Scrawly.Games.WordStats, record?: false` turns the
  writes off; the test config does, and the tests of the stats turn them
  back on.
  """

  require Logger

  alias Scrawly.Games
  alias Scrawly.Games.WordList

  @thresholds [
    min_rounds: 20,
    easy_below: 0.40,
    hard_above: 0.60,
    min_offered: 30,
    picked_below: 0.10
  ]

  @columns ~w(text difficulty theme list offered picked pick_rate rounds guessers correct
              guess_rate first_guess_rounds first_guess_avg_s)

  # ── Recording ─────────────────────────────────────────────────────────────

  @doc """
  The drawer is shown `state.word_choices`: `offered` +1 for each curated
  one. Always `:ok`.
  """
  @spec offered(map) :: :ok
  def offered(%{word_choices: choices} = state) when is_list(choices) do
    if curated_room?(state) do
      for choice <- choices, curated?(choice), do: %{text: choice.text, offered: 1}
    else
      []
    end
    |> write(:offered)
  end

  def offered(_state), do: :ok

  @doc """
  `choice` (a `t:Scrawly.Games.RoomServer.GameFlow.choice/0`) was chosen,
  by the drawer or by the choice timer: `picked` +1 if it is curated.
  Always `:ok`.
  """
  @spec picked(map, map) :: :ok
  def picked(state, choice) do
    if curated_room?(state) and curated?(choice),
      do: write([%{text: choice.text, picked: 1}], :picked),
      else: :ok
  end

  @doc """
  The round of `state.current_word` was played to its end (time up or
  everyone guessed; `state` is the room at that moment): `rounds` +1, its
  guessers, correct guessers and first-guess time added, if the word is
  curated. Always `:ok`.
  """
  @spec round_played(map) :: :ok
  def round_played(%{current_word: word, current_difficulty: difficulty} = state) do
    if curated_room?(state) and curated?(%{text: word, difficulty: difficulty}),
      do: write([Map.put(round_counts(state), :text, word)], :round),
      else: :ok
  end

  def round_played(_state), do: :ok

  defp curated_room?(state), do: Map.get(state, :word_source) == :local

  defp curated?(%{text: text, difficulty: difficulty})
       when is_binary(text) and difficulty != nil,
       do: WordList.entry(text) != nil

  defp curated?(_choice), do: false

  defp round_counts(state) do
    guessers =
      for %{id: id} <- state.players,
          id != state.current_drawer_id,
          Map.has_key?(state.round_start_scores, id),
          do: id

    correct = Enum.filter(guessers, &(&1 in state.correct_guessers))

    first_guess_ms =
      state.guess_times
      |> Map.take(correct)
      |> Map.values()
      |> Enum.min(fn -> nil end)

    %{
      rounds: 1,
      guessers: length(guessers),
      correct: length(correct),
      first_guess_ms_sum: first_guess_ms || 0,
      first_guess_rounds: if(first_guess_ms, do: 1, else: 0)
    }
  end

  defp write([], _moment), do: :ok

  defp write(rows, moment) do
    if record?() do
      case Task.Supervisor.start_child(Scrawly.TaskSupervisor, fn -> save(rows, moment) end) do
        {:ok, _pid} -> :ok
        {:error, reason} -> log_failure(moment, reason)
      end
    end

    :ok
  catch
    :exit, _reason ->
      log_failure(moment, :task_supervisor_down)
      :ok
  end

  defp record?, do: Keyword.get(Application.get_env(:scrawly, __MODULE__, []), :record?, true)

  defp save(rows, moment) do
    case Games.record_word_stats(rows,
           bulk_options: [return_errors?: true, stop_on_error?: true, return_records?: false]
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> log_failure(moment, errors)
    end
  rescue
    error -> log_failure(moment, error)
  catch
    kind, _reason -> log_failure(moment, kind)
  end

  defp log_failure(moment, reason),
    do: Logger.warning("word stats not saved (#{moment}): #{reason_tag(reason)}")

  # Why a write failed, for the log: error types and database error codes,
  # never an error's message or fields (they hold the texts and counts).
  defp reason_tag([_ | _] = errors),
    do: errors |> Enum.map(&reason_tag/1) |> Enum.uniq() |> Enum.join(", ")

  defp reason_tag(%{__struct__: module, errors: [_ | _] = errors}),
    do: "#{inspect(module)} (#{reason_tag(errors)})"

  defp reason_tag(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code),
    do: "Postgrex.Error #{code}"

  # Ash keeps an unexpected exception as its message alone ("** (Postgrex.Error)
  # ERROR P0001 (raise_exception) ..." and the details): only its type and
  # SQLSTATE name are taken from it.
  defp reason_tag(%Ash.Error.Unknown.UnknownError{error: message}) when is_binary(message) do
    type =
      case Regex.run(~r/\A\*\* \(([\w.]+)\)/, message) do
        [_, type] -> type
        nil -> "Ash.Error.Unknown.UnknownError"
      end

    case Regex.run(~r/ERROR [0-9A-Z]{5} \(([a-z_]+)\)/, message) do
      [_, code] -> "#{type} #{code}"
      nil -> type
    end
  end

  defp reason_tag(%{__struct__: _module, error: %{__struct__: _} = inner}), do: reason_tag(inner)
  defp reason_tag(%{__struct__: module}), do: inspect(module)
  defp reason_tag(reason) when is_atom(reason), do: inspect(reason)
  defp reason_tag(_reason), do: "unexpected reply"

  # ── Report ────────────────────────────────────────────────────────────────

  @doc """
  The entries whose numbers say their label or their place in the list
  should change, as CSV: three lists, one after the other.

    * `too_hard`: labelled easy, at least `min_rounds` rounds, guessed by
      fewer than `easy_below` of the players who could have;
    * `too_easy`: labelled hard, at least `min_rounds` rounds, guessed by
      more than `hard_above`;
    * `rarely_picked`: offered at least `min_offered` times, picked less than
      `picked_below` of them.

  The columns are words.csv's (`text,difficulty,theme`, so a line's first
  three fields are the entry as the file has it), then `list` and the
  numbers: `offered`, `picked`, `pick_rate`, `rounds`, `guessers`,
  `correct`, `guess_rate` (correct / guessers), `first_guess_rounds` and
  `first_guess_avg_s` (the mean seconds to the first correct guess in
  those rounds). Rates have three decimals; a rate or mean with nothing to
  divide by is empty. Each list is sorted by its rate, the worst first. An
  entry can be in two lists. Stats of a text that is no longer in the file
  are left out. With no stats at all it is just the header line.

  Options override the thresholds: #{inspect(@thresholds)}.

  It only reads, in a read-only transaction (rolled back). On a running
  release: `bin/scrawly rpc "Scrawly.Games.WordStats.report() |>
  IO.puts()"`; with only the Repo started: `Scrawly.Release.word_report/1`
  or `mix scrawly.word_report`.
  """
  @spec report(keyword) :: String.t()
  def report(opts \\ []) do
    opts = Keyword.validate!(opts, @thresholds)
    stats = read_only(&Games.list_word_stats!/0)
    measured = for stat <- stats, entry = WordList.entry(stat.text), do: {entry, stat}

    lines =
      for {list, rows} <- [
            too_hard: too_hard(measured, opts),
            too_easy: too_easy(measured, opts),
            rarely_picked: rarely_picked(measured, opts)
          ],
          {entry, stat} <- rows,
          do: line(entry, stat, list)

    Enum.join([Enum.join(@columns, ",") | lines], "\n")
  end

  defp too_hard(measured, opts) do
    measured
    |> Enum.filter(fn {entry, stat} ->
      entry.difficulty == :easy and stat.rounds >= opts[:min_rounds] and
        below?(guess_rate(stat), opts[:easy_below])
    end)
    |> Enum.sort_by(fn {entry, stat} -> {guess_rate(stat), entry.text} end)
  end

  defp too_easy(measured, opts) do
    measured
    |> Enum.filter(fn {entry, stat} ->
      entry.difficulty == :hard and stat.rounds >= opts[:min_rounds] and
        above?(guess_rate(stat), opts[:hard_above])
    end)
    |> Enum.sort_by(fn {entry, stat} -> {-guess_rate(stat), entry.text} end)
  end

  defp rarely_picked(measured, opts) do
    measured
    |> Enum.filter(fn {_entry, stat} ->
      stat.offered >= opts[:min_offered] and below?(pick_rate(stat), opts[:picked_below])
    end)
    |> Enum.sort_by(fn {entry, stat} -> {pick_rate(stat), entry.text} end)
  end

  defp below?(rate, threshold), do: rate != nil and rate < threshold
  defp above?(rate, threshold), do: rate != nil and rate > threshold

  defp guess_rate(%{guessers: guessers, correct: correct}) when guessers > 0,
    do: correct / guessers

  defp guess_rate(_stat), do: nil

  defp pick_rate(%{offered: offered, picked: picked}) when offered > 0, do: picked / offered
  defp pick_rate(_stat), do: nil

  defp first_guess_avg_s(%{first_guess_rounds: rounds, first_guess_ms_sum: ms}) when rounds > 0,
    do: ms / rounds / 1000

  defp first_guess_avg_s(_stat), do: nil

  defp line(entry, stat, list) do
    Enum.join(
      [
        entry.text,
        entry.difficulty,
        entry.theme,
        list,
        stat.offered,
        stat.picked,
        decimal(pick_rate(stat), 3),
        stat.rounds,
        stat.guessers,
        stat.correct,
        decimal(guess_rate(stat), 3),
        stat.first_guess_rounds,
        decimal(first_guess_avg_s(stat), 1)
      ],
      ","
    )
  end

  defp decimal(nil, _places), do: ""
  defp decimal(number, places), do: :erlang.float_to_binary(number / 1, decimals: places)

  # Runs `fun` in a read-only transaction, which is then rolled back: the
  # report can't write, wherever it runs.
  defp read_only(fun) do
    {:error, {:read, result}} =
      Scrawly.Repo.transaction(fn ->
        Scrawly.Repo.query!("SET TRANSACTION READ ONLY")
        Scrawly.Repo.rollback({:read, fun.()})
      end)

    result
  end
end
