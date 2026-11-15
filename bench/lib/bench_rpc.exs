# Server-side helpers for the client benchmark (bench/drawing_client.mjs),
# compiled into the running bench release through
# `bench/prod_server.sh rpc`. Only for the scratch release: it creates
# BENCH users and rooms and loads fixture strokes through the app's own
# entry points.
defmodule BenchRpc do
  @moduledoc false

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.{DemoBoardServer, RoomServer}
  alias Scrawly.Games.RoomServer.GameFlow

  def strokes(dir, canvas) do
    key = {__MODULE__, canvas}

    case :persistent_term.get(key, nil) do
      nil ->
        %{"strokes" => list} =
          Path.join(dir, "#{canvas}-500.json") |> File.read!() |> Jason.decode!()

        list =
          Enum.map(list, fn s ->
            %{
              id: :binary.copy(s["id"]),
              path: :binary.copy(s["path"]),
              color: s["color"],
              width: s["width"]
            }
          end)

        :persistent_term.put(key, list)
        list

      list ->
        list
    end
  end

  # Two registered users, a room and a game in :drawing whose round timers
  # are cancelled (no time-up, no hint reveals during the run). Prints JSON.
  def setup(password) do
    n = System.unique_integer([:positive])

    mk = fn tag ->
      email = "bench-#{tag}-#{n}@example.com"
      {:ok, user} = Accounts.register_with_password(email, password, authorize?: false)
      user
    end

    host = mk.("h")
    guest = mk.("v")

    room =
      Games.create_room!(%{
        name: "BENCH room #{n}",
        max_players: 12,
        creator_id: host.id,
        round_duration: 300
      })

    Accounts.join_room!(host, room.id)
    Games.join_room!(room.id, host.id)
    {:ok, pid} = RoomServer.ensure_started(room.id)

    {:ok, _} =
      RoomServer.join(room.id, %{
        id: guest.id,
        username: guest.username,
        score: 0,
        avatar_id: "a-mushroom",
        avatar_color: "3"
      })

    Accounts.join_room!(guest, room.id)
    Games.join_room!(room.id, guest.id)

    {:ok, started} =
      RoomServer.start_game(room.id, host.id, %{word_choices: [%{text: "zzyzx", difficulty: nil}]})

    drawer_id = started.current_drawer_id
    {:ok, %{phase: :drawing}} = RoomServer.choose_word(room.id, drawer_id, "zzyzx")
    freeze(pid)

    {drawer, viewer} = if drawer_id == host.id, do: {host, guest}, else: {guest, host}

    IO.puts(
      Jason.encode!(%{
        room_id: room.id,
        drawer: %{id: drawer.id, email: to_string(drawer.email)},
        viewer: %{id: viewer.id, email: to_string(viewer.email)}
      })
    )
  end

  defp freeze(pid) do
    :sys.replace_state(pid, fn s ->
      s
      |> GameFlow.cancel_turn_timers()
      |> Map.put(:round_deadline, System.monotonic_time(:millisecond) + 3_600_000)
    end)
  end

  defp room_pid(room_id) do
    [{pid, _}] = Registry.lookup(Scrawly.RoomRegistry, room_id)
    pid
  end

  defp reset_rate(pid), do: :sys.replace_state(pid, &%{&1 | stroke_rate_limits: %{}})

  # Clears the room and commits its first `count` fixture strokes as the
  # drawer, through RoomServer (each one published as :stroke_completed). The
  # drawer's op rate limit is reset between commits: it isn't measured.
  def load_room(dir, room_id, drawer_id, count) do
    pid = room_pid(room_id)
    freeze(pid)
    reset_rate(pid)
    :ok = RoomServer.clear_drawing(room_id, drawer_id)

    strokes(dir, "game")
    |> Enum.take(count)
    |> Enum.with_index(1)
    |> Enum.each(fn {s, i} ->
      if rem(i, 30) == 0, do: reset_rate(pid)
      :ok = RoomServer.append_drawing(room_id, drawer_id, s)
    end)

    reset_rate(pid)
    IO.puts(Jason.encode!(%{room_strokes: length(:sys.get_state(pid).drawing_strokes)}))
  end

  # The demo board: cleared, then its first `count` fixture strokes added
  # through DemoBoardServer (what DemoBoardChannel does for each stroke).
  def load_demo(dir, count) do
    DemoBoardServer.clear()

    strokes(dir, "demo")
    |> Enum.take(count)
    |> Enum.each(fn s ->
      DemoBoardServer.add_stroke(%{path: s.path, color: s.color, width: s.width, stroke_id: s.id})
    end)

    IO.puts(Jason.encode!(%{demo_strokes: length(DemoBoardServer.get_strokes())}))
  end

  # Load-and-clear cycles for the leak check: each cycle clears the room and
  # the demo board, then fills them again (room_count strokes committed one
  # by one, demo_count added one by one), pausing so the pages keep up. Ends
  # loaded.
  def cycles(dir, room_id, drawer_id, room_count, demo_count, cycles, pause_ms) do
    pid = room_pid(room_id)
    room = strokes(dir, "game") |> Enum.take(room_count)
    demo = strokes(dir, "demo") |> Enum.take(demo_count)

    for _ <- 1..cycles do
      reset_rate(pid)
      :ok = RoomServer.clear_drawing(room_id, drawer_id)
      DemoBoardServer.clear()
      Process.sleep(pause_ms)

      room
      |> Enum.with_index(1)
      |> Enum.each(fn {s, i} ->
        if rem(i, 30) == 0, do: reset_rate(pid)
        :ok = RoomServer.append_drawing(room_id, drawer_id, s)
      end)

      Enum.each(demo, fn s ->
        DemoBoardServer.add_stroke(%{
          path: s.path,
          color: s.color,
          width: s.width,
          stroke_id: s.id
        })
      end)

      Process.sleep(pause_ms)
    end

    reset_rate(pid)
    IO.puts(Jason.encode!(%{cycles: cycles}))
  end

  # Ends the bench game: the room process is stopped (its rows stay in the
  # scratch database, dropped with it).
  def teardown(room_id) do
    case Registry.lookup(Scrawly.RoomRegistry, room_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Scrawly.RoomSupervisor, pid)
      [] -> :ok
    end

    DemoBoardServer.clear()
    IO.puts(Jason.encode!(%{ok: true}))
  end
end
