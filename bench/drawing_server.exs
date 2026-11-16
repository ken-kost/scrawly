# Server-side drawing benchmark (bench/README.md).
#
#   MIX_TEST_PARTITION=_bench MIX_ENV=test mix run --no-start bench/drawing_server.exs [OUT.json]
#
# Runs in the test environment against its own scratch database
# (scrawly_test_bench, made by `MIX_TEST_PARTITION=_bench MIX_ENV=test mix
# ash.setup`) inside one SQL sandbox transaction that is rolled back at the
# end, so it leaves no rows behind. It starts the endpoint on a spare port
# (BENCH_WS_PORT, default 4199) for the fan-out part; its WebSocket clients
# run in a separate BEAM (a :peer node), so the scheduler numbers count the
# server side only.
#
# Stroke sets: bench/fixtures/{game,demo}-500.json (the 100- and 300-stroke
# sets are their first 100 and 300 strokes). Every path is copied out of the
# decoded file (:binary.copy/1), as the app's own decoders make one binary
# per path; a sub-binary would pin the whole file and distort the memory
# numbers.

defmodule Bench do
  @moduledoc false

  def now_ns, do: System.monotonic_time(:nanosecond)

  # Runs `setup` (untimed) then `timed`, `warmup + n` times; returns the
  # timed durations in microseconds.
  def sample(n, setup, timed, warmup \\ 20) do
    for i <- 1..(warmup + n), reduce: [] do
      acc ->
        ctx = setup.()
        t0 = now_ns()
        timed.(ctx)
        us = (now_ns() - t0) / 1000
        if i > warmup, do: [us | acc], else: acc
    end
  end

  def stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)

    %{
      n: n,
      median_us: round3(pct(sorted, 50)),
      p95_us: round3(pct(sorted, 95)),
      min_us: round3(hd(sorted)),
      max_us: round3(List.last(sorted))
    }
  end

  def pct(sorted, p) do
    n = length(sorted)
    i = min(n - 1, max(0, ceil(p / 100 * n) - 1))
    Enum.at(sorted, i)
  end

  def round3(x) when is_float(x), do: Float.round(x, 3)
  def round3(x), do: x

  def log(msg), do: IO.puts(:stderr, msg)

  def fmt(%{median_us: m, p95_us: p}), do: "median #{m} us, p95 #{p} us"

  # Process memory: the process itself (heap, stack, mailbox) and the
  # off-heap (refc) binaries it references, each binary counted once and in
  # full (they may be shared with other processes).
  def mem(pid) do
    [memory: memory, total_heap_size: heap_words, binary: bins] =
      :erlang.process_info(pid, [:memory, :total_heap_size, :binary])

    bin_bytes = bins |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    # The state's own size (a flat copy, in words), which unlike the heap
    # doesn't move with the heap's allocation steps.
    state_words = pid |> :sys.get_state() |> :erts_debug.flat_size()

    %{
      process_bytes: memory,
      heap_bytes: heap_words * :erlang.system_info(:wordsize),
      state_term_bytes: state_words * :erlang.system_info(:wordsize),
      binary_bytes: bin_bytes,
      binary_count: length(Enum.uniq_by(bins, &elem(&1, 0))),
      total_bytes: memory + bin_bytes
    }
  end

  def load_fixture(name) do
    path = Path.expand("fixtures/#{name}.json", __DIR__)
    %{"strokes" => strokes} = path |> File.read!() |> Jason.decode!()

    Enum.map(strokes, fn s ->
      stroke = %{
        id: :binary.copy(s["id"]),
        path: :binary.copy(s["path"]),
        color: :binary.copy(s["color"]),
        width: s["width"],
        kind: s["kind"]
      }

      # The fills sets (bench/fixtures/generate_fills.mjs): a fill carries
      # `fill: true`, as the room and the board store it.
      if s["fill"] == true, do: Map.put(stroke, :fill, true), else: stroke
    end)
  end
end

# A minimal WebSocket client (RFC 6455, text frames only), loaded into the
# :peer node that plays the visitors' browsers.
{:module, ws_mod, ws_bin, _} =
  defmodule Bench.WS do
    @moduledoc false

    # BENCH_WS_DEFLATE=1 (read in the peer): the visitors offer
    # permessage-deflate, as browsers do; the server compresses only if its
    # socket allows it (`websocket: [compress: true]`).
    def deflate?, do: System.get_env("BENCH_WS_DEFLATE") == "1"

    def connect(port, path) do
      {:ok, sock} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [
          :binary,
          active: false,
          packet: :raw,
          nodelay: true
        ])

      key = Base.encode64(:rand.bytes(16))

      :ok =
        :gen_tcp.send(
          sock,
          "GET #{path} HTTP/1.1\r\nHost: localhost:#{port}\r\nUpgrade: websocket\r\n" <>
            "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n" <>
            if(deflate?(), do: "Sec-WebSocket-Extensions: permessage-deflate\r\n", else: "") <>
            "\r\n"
        )

      {:ok, rest} = read_headers(sock, "")
      {sock, rest}
    end

    defp read_headers(sock, acc) do
      case :binary.split(acc, "\r\n\r\n") do
        [head, rest] ->
          if String.starts_with?(head, "HTTP/1.1 101"), do: {:ok, rest}, else: {:error, head}

        [_] ->
          {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
          read_headers(sock, acc <> data)
      end
    end

    def send_text(sock, text) do
      len = byte_size(text)
      mask = :rand.bytes(4)

      header =
        cond do
          len < 126 -> <<1::1, 0::3, 1::4, 1::1, len::7>>
          len < 65_536 -> <<1::1, 0::3, 1::4, 1::1, 126::7, len::16>>
          true -> <<1::1, 0::3, 1::4, 1::1, 127::7, len::64>>
        end

      :gen_tcp.send(sock, [header, mask, mask_payload(text, mask)])
    end

    defp mask_payload(data, mask) do
      len = byte_size(data)
      keystream = mask |> :binary.copy(div(len, 4) + 1) |> binary_part(0, len)
      :crypto.exor(data, keystream)
    end

    # Complete server frames (unmasked) from `buf`: {[{rsv1, payload}], rest}.
    # rsv1: the frame is compressed (permessage-deflate).
    def frames(buf, acc \\ []) do
      case buf do
        <<_fin::1, c::1, _::2, _op::4, 0::1, 127::7, len::64, payload::binary-size(len), rest::binary>> ->
          frames(rest, [{c, payload} | acc])

        <<_fin::1, c::1, _::2, _op::4, 0::1, 126::7, len::16, payload::binary-size(len), rest::binary>> ->
          frames(rest, [{c, payload} | acc])

        <<_fin::1, c::1, _::2, _op::4, 0::1, len::7, payload::binary-size(len), rest::binary>>
        when len < 126 ->
          frames(rest, [{c, payload} | acc])

        _ ->
          {Enum.reverse(acc), buf}
      end
    end

    # A frame's message: inflated with the connection's inflater when it
    # came compressed.
    def message(_z, {0, payload}), do: payload

    def message(z, {1, payload}),
      do: z |> :zlib.inflate(payload <> <<0, 0, 255, 255>>) |> IO.iodata_to_binary()

    def inflater do
      z = :zlib.open()
      :ok = :zlib.inflateInit(z, -15)
      z
    end

    # With 500 strokes on the board: a visitor joins and gets the snapshot.
    # Returns its size on the wire, its size, and join to receipt in ms.
    def snapshot_probe(port) do
      {sock, rest} = connect(port, "/socket/websocket?vsn=2.0.0")
      z = inflater()
      t0 = System.monotonic_time(:microsecond)
      send_text(sock, ~s(["1","1","demo:board","phx_join",{}]))
      result = await_snapshot(sock, z, rest, t0)
      :gen_tcp.close(sock)
      result
    end

    defp await_snapshot(sock, z, buf, t0) do
      {got, rest} = frames(buf)

      found =
        Enum.find_value(got, fn {_c, payload} = f ->
          msg = message(z, f)

          if :binary.match(msg, "\"strokes\"") != :nomatch,
            do: %{wire_bytes: byte_size(payload), bytes: byte_size(msg)}
        end)

      if found do
        Map.put(found, :ms, (System.monotonic_time(:microsecond) - t0) / 1000)
      else
        {:ok, data} = :gen_tcp.recv(sock, 0, 10_000)
        await_snapshot(sock, z, rest <> data, t0)
      end
    end

    # ── The visitors ───────────────────────────────────────────────────

    # A visitor on the home page: joins demo:board and records, for every
    # relayed chunk, now - seq (the sender puts its send time, in this
    # node's OS clock in us, in seq).
    def subscriber(port, parent) do
      # Watch only: no board token.
      {sock, rest} = connect(port, "/socket/websocket?vsn=2.0.0")
      send_text(sock, ~s(["1","1","demo:board","phx_join",{}]))
      :ok = :inet.setopts(sock, active: true)
      send(parent, {:joined, self()})
      sub_loop(sock, rest, %{lat: [], removed: [], frames: 0, bytes: 0, wire: 0, z: inflater()})
    end

    defp sub_loop(sock, buf, st) do
      receive do
        {:tcp, ^sock, data} ->
          now = System.os_time(:microsecond)
          {got, rest} = frames(buf <> data)

          st =
            Enum.reduce(got, st, fn {_c, wire} = f, st ->
              p = message(st.z, f)

              st = %{
                st
                | frames: st.frames + 1,
                  bytes: st.bytes + byte_size(p),
                  wire: st.wire + byte_size(wire)
              }

              case :binary.match(p, "\"stroke_chunk\"") do
                :nomatch ->
                  # A board undo's push: when it arrived (in order, one per
                  # undo).
                  case :binary.match(p, "\"stroke_removed\"") do
                    :nomatch -> st
                    _ -> %{st | removed: [now | st.removed]}
                  end

                _ ->
                  case :binary.match(p, "\"seq\":") do
                    {at, len} ->
                      {seq, _} = Integer.parse(binary_part(p, at + len, byte_size(p) - at - len))
                      %{st | lat: [now - seq | st.lat]}

                    :nomatch ->
                      st
                  end
              end
            end)

          sub_loop(sock, rest, st)

        {:report, from} ->
          send(from, {:report, self(), %{Map.delete(st, :z) | removed: Enum.reverse(st.removed)}})
          sub_loop(sock, buf, %{st | lat: [], removed: [], frames: 0, bytes: 0, wire: 0})

        {:tcp_closed, ^sock} ->
          :closed

        :stop ->
          :gen_tcp.close(sock)
      end
    end

    # The drawer: joins with a board token (ScrawlyWeb.BoardToken: a socket
    # without one may not draw), then pushes one chunk every `interval_ms`
    # for `duration_ms`, a new stroke id every 40 chunks, deltas cycled from
    # `deltas`.
    def sender(port, board_token, deltas, interval_ms, duration_ms, parent) do
      {sock, _rest} = connect(port, "/socket/websocket?vsn=2.0.0&board_token=#{board_token}")
      send_text(sock, ~s(["1","1","demo:board","phx_join",{}]))
      Process.sleep(300)
      deadline = System.monotonic_time(:millisecond) + duration_ms
      n = send_loop(sock, List.to_tuple(deltas), 0, interval_ms, deadline)
      send(parent, {:sent, n})
      Process.sleep(500)
      :gen_tcp.close(sock)
    end

    defp send_loop(sock, deltas, i, interval_ms, deadline) do
      if System.monotonic_time(:millisecond) >= deadline do
        i
      else
        t0 = System.monotonic_time(:millisecond)
        delta = elem(deltas, rem(i, tuple_size(deltas)))
        seq = System.os_time(:microsecond)
        stroke_id = "bench-#{div(i, 40)}"

        msg =
          ~s(["1","#{i + 2}","demo:board","stroke_chunk",{"stroke_id":"#{stroke_id}","seq":#{seq},"delta":"#{delta}","color":"#000000","width":4}])

        :ok = send_text(sock, msg)
        left = interval_ms - (System.monotonic_time(:millisecond) - t0)
        if left > 0, do: Process.sleep(left)
        send_loop(sock, deltas, i + 1, interval_ms, deadline)
      end
    end

    # Runs in the peer: starts `n` subscribers and waits until all joined.
    def start_subscribers(port, n) do
      me = self()

      pids =
        for _ <- 1..n do
          spawn(fn -> subscriber(port, me) end)
        end

      for _ <- 1..n do
        receive do
          {:joined, _} -> :ok
        after
          10_000 -> raise "subscriber did not join"
        end
      end

      :persistent_term.put(:bench_subs, pids)
      Process.sleep(500)
      # Drop what the joins brought (replies, snapshots).
      collect(pids)
      length(pids)
    end

    def collect(pids \\ :persistent_term.get(:bench_subs)) do
      me = self()
      Enum.each(pids, &send(&1, {:report, me}))

      for _ <- pids do
        receive do
          {:report, _pid, st} -> st
        after
          10_000 -> %{lat: [], removed: [], frames: 0, bytes: 0, wire: 0}
        end
      end
    end

    def stop_subscribers do
      Enum.each(:persistent_term.get(:bench_subs, []), &send(&1, :stop))
      :persistent_term.erase(:bench_subs)
      :ok
    end

    # Runs in the peer: the drawer's session; returns the chunks sent.
    def run_sender(port, board_token, deltas, interval_ms, duration_ms) do
      me = self()
      spawn(fn -> sender(port, board_token, deltas, interval_ms, duration_ms, me) end)

      receive do
        {:sent, n} -> n
      after
        duration_ms + 15_000 -> raise "sender timed out"
      end
    end
  end

alias Scrawly.{Accounts, Games}
alias Scrawly.Games.{DemoBoardServer, RoomServer, StrokeRules}
alias Scrawly.Games.RoomServer.GameFlow

out_path =
  case System.argv() do
    [path | _] -> path
    [] -> Path.expand("results/server-#{Date.utc_today()}.json", __DIR__)
  end

ws_port = String.to_integer(System.get_env("BENCH_WS_PORT", "4199"))
iterations = String.to_integer(System.get_env("BENCH_ITERATIONS", "400"))
t_start = System.monotonic_time(:millisecond)

# ── Start the app with the endpoint listening (fan-out) ─────────────────
endpoint = Application.get_env(:scrawly, ScrawlyWeb.Endpoint)

Application.put_env(
  :scrawly,
  ScrawlyWeb.Endpoint,
  Keyword.merge(endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: ws_port])
)

Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:scrawly)

# Hologram's realtime runtime is off in the test env, so its PubSub is not
# started (test/test_helper.exs does the same): the room's broadcasts then
# go to zero subscribers instead of raising.
unless Process.whereis(Hologram.PubSub) do
  {:ok, _} =
    Supervisor.start_link([{Phoenix.PubSub, name: Hologram.PubSub}], strategy: :one_for_one)
end

:ok = Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
Ecto.Adapters.SQL.Sandbox.mode(Scrawly.Repo, {:shared, self()})

game = Bench.load_fixture("game-500")
demo = Bench.load_fixture("demo-500")

# Every fixture stroke passes the room's own checks, and the set fits the
# canvas budget.
Enum.reduce(game, [], fn s, acc ->
  {:ok, stroke} = StrokeRules.check_append(acc, Map.take(s, [:id, :path, :color, :width]))
  [stroke | acc]
end)

game = Enum.map(game, &Map.take(&1, [:id, :path, :color, :width, :kind]))
room_strokes = Enum.map(game, &Map.take(&1, [:id, :path, :color, :width]))

# The sets with fills (every tenth stroke a fill): they pass the same
# checks, and are stored as the room stores them (StrokeRules.validate/1).
game_fills = Bench.load_fixture("game-fills-500")
demo_fills = Bench.load_fixture("demo-fills-500")

room_fill_strokes =
  game_fills
  |> Enum.reduce([], fn s, acc ->
    {:ok, stroke} = StrokeRules.check_append(acc, Map.take(s, [:id, :path, :color, :width, :fill]))
    [stroke | acc]
  end)
  |> Enum.reverse()

demo_fill_strokes =
  Enum.map(demo_fills, fn s ->
    Map.merge(
      %{path: s.path, color: s.color, width: s.width, stroke_id: s.id, owner: "anon:bench", gesture: s.id},
      Map.take(s, [:fill])
    )
  end)

# DemoBoardServer stores every stroke with its owner (an actor key) and
# gesture.
demo_strokes =
  Enum.map(demo, fn s ->
    %{
      path: s.path,
      color: s.color,
      width: s.width,
      stroke_id: s.id,
      owner: "anon:bench",
      gesture: s.id
    }
  end)

# The stroke committed in the commit benchmarks: the set's first medium
# stroke (~1.5 KB) under an id of its own.
probe = game |> Enum.find(&(&1.kind == "medium")) |> Map.take([:path, :color, :width])
room_probe = Map.put(probe, :id, "bench-probe")

demo_probe = %{
  path: probe.path,
  color: probe.color,
  width: probe.width,
  stroke_id: "bench-probe",
  owner: "anon:bench"
}

# The drawer's board token, for an anonymous visitor's session.
board_token =
  ScrawlyWeb.BoardToken.mint(%Hologram.Server{session: %{}, session_id: "bench-drawer"})

# ── A room in :drawing ───────────────────────────────────────────────────
n = System.unique_integer([:positive])

mk_user = fn tag ->
  Ash.create!(
    Accounts.User,
    %{email: "bench-#{tag}-#{n}@example.com", username: "BENCH#{tag}#{n}"},
    authorize?: false
  )
end

host = mk_user.("h")
guest = mk_user.("v")

room =
  Games.create_room!(%{
    name: "BENCH room #{n}",
    max_players: 12,
    creator_id: host.id,
    round_duration: 300
  })

Accounts.join_room!(host, room.id)
Games.join_room!(room.id, host.id)
{:ok, room_pid} = RoomServer.ensure_started(room.id)

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

drawer = started.current_drawer_id
viewer = if drawer == host.id, do: guest.id, else: host.id
{:ok, %{phase: :drawing}} = RoomServer.choose_word(room.id, drawer, "zzyzx")

# The round's expiry and hint reveals are cancelled, so the round outlasts
# the benchmark and nothing else runs in the room meanwhile.
:sys.replace_state(room_pid, fn s ->
  s
  |> GameFlow.cancel_turn_timers()
  |> Map.put(:round_deadline, System.monotonic_time(:millisecond) + 3_600_000)
end)

set_room = fn strokes ->
  :sys.replace_state(room_pid, fn s ->
    %{s | drawing_strokes: strokes, stroke_rate_limits: %{}, stroke_op: nil}
  end)

  :ok
end

demo_pid = Process.whereis(DemoBoardServer)

# Since #44 the board keeps its count and path bytes beside the list (and
# caps the bytes): kept in step here (unused keys before that).
set_demo = fn strokes ->
  :sys.replace_state(demo_pid, fn s ->
    Map.merge(s, %{
      strokes: strokes,
      count: length(strokes),
      bytes: Enum.reduce(strokes, 0, &(byte_size(&1.path) + &2))
    })
  end)

  :ok
end

# The newest strokes within the board's byte cap (DemoBoardServer.max_bytes/0,
# since #44; no cap before).
cap_demo = fn strokes ->
  if function_exported?(DemoBoardServer, :max_bytes, 0) do
    max = DemoBoardServer.max_bytes()

    strokes
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn s, {kept, bytes} ->
      size = bytes + byte_size(s.path)
      if size > max, do: {:halt, {kept, bytes}}, else: {:cont, {[s | kept], size}}
    end)
    |> elem(0)
  else
    strokes
  end
end

# A cheap round trip to the demo board (a system message, no state copied):
# a cast followed by it has been handled when it returns.
demo_barrier = fn -> :sys.statistics(demo_pid, :get) end

results = %{
  meta: %{
    date: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
    otp: System.otp_release(),
    elixir: System.version(),
    schedulers: System.schedulers_online(),
    iterations: iterations,
    probe_stroke_bytes: byte_size(probe.path),
    fixture_path_bytes: StrokeRules.canvas_bytes(room_strokes)
  }
}

# ── 1. Commits ──────────────────────────────────────────────────────────
Bench.log("commit: room and demo board at 0/100/300/499 strokes")

commit =
  for held <- [0, 100, 300, 499], into: %{} do
    prefix = Enum.take(room_strokes, held)
    # What the board holds after taking `held` strokes: since #44 its byte
    # cap keeps only the newest that fit (at 499 fixture strokes, fewer).
    demo_prefix = demo_strokes |> Enum.take(held) |> cap_demo.()

    room_stats =
      Bench.sample(
        iterations,
        fn -> set_room.(prefix) end,
        fn _ -> :ok = RoomServer.append_drawing(room.id, drawer, room_probe) end
      )
      |> Bench.stats()

    demo_stats =
      Bench.sample(
        iterations,
        fn -> set_demo.(demo_prefix) end,
        fn _ ->
          DemoBoardServer.add_stroke(demo_probe)
          demo_barrier.()
        end
      )
      |> Bench.stats()

    # Pieces of the room's commit, run here (pure): the limit check and the
    # append.
    check =
      Bench.sample(iterations, fn -> :ok end, fn _ ->
        StrokeRules.check_append(prefix, room_probe)
      end)
      |> Bench.stats()

    append =
      Bench.sample(iterations, fn -> :ok end, fn _ -> prefix ++ [room_probe] end) |> Bench.stats()

    # The same check with the count and path bytes kept in the state (what
    # #44 tried): validation plus two comparisons, no walk of the list.
    prefix_bytes = StrokeRules.canvas_bytes(prefix)

    check_with_totals =
      Bench.sample(iterations, fn -> :ok end, fn _ ->
        {:ok, s} = StrokeRules.validate(room_probe)

        held < StrokeRules.max_strokes() and
          prefix_bytes + byte_size(s.path) <= StrokeRules.max_canvas_bytes()
      end)
      |> Bench.stats()

    Bench.log("  #{held}: room #{Bench.fmt(room_stats)} | demo #{Bench.fmt(demo_stats)}")

    {held,
     %{
       demo_strokes_held: length(demo_prefix),
       room: room_stats,
       demo: demo_stats,
       room_check_append: check,
       room_check_with_totals: check_with_totals,
       room_list_append: append
     }}
  end

barrier_only =
  Bench.sample(iterations, fn -> :ok end, fn _ -> demo_barrier.() end) |> Bench.stats()

results = Map.put(results, :commit, Map.put(commit, :demo_barrier_round_trip, barrier_only))

# ── 2. Undo and clear at 500 ─────────────────────────────────────────────
Bench.log("undo / clear at 500")
last_id = List.last(room_strokes).id

undo =
  Bench.sample(iterations, fn -> set_room.(room_strokes) end, fn _ ->
    :ok = RoomServer.undo_drawing(room.id, drawer, last_id)
  end)
  |> Bench.stats()

clear =
  Bench.sample(iterations, fn -> set_room.(room_strokes) end, fn _ ->
    :ok = RoomServer.clear_drawing(room.id, drawer)
  end)
  |> Bench.stats()

demo_clear =
  Bench.sample(iterations, fn -> set_demo.(demo_strokes) end, fn _ ->
    DemoBoardServer.clear()
    demo_barrier.()
  end)
  |> Bench.stats()

Bench.log(
  "  room undo #{Bench.fmt(undo)} | room clear #{Bench.fmt(clear)} | demo clear #{Bench.fmt(demo_clear)}"
)

results = Map.put(results, :at_500, %{room_undo: undo, room_clear: clear, demo_clear: demo_clear})

# ── 3. Process memory holding each fixture ───────────────────────────────
# Filled through the real entry points (RoomServer.append_drawing/3,
# DemoBoardServer.add_stroke/1), garbage-collected before each reading.
Bench.log("memory")
set_room.([])
set_demo.([])
:erlang.garbage_collect(room_pid)
:erlang.garbage_collect(demo_pid)
room_mem = %{0 => Bench.mem(room_pid)}
demo_mem = %{0 => Bench.mem(demo_pid)}

{room_mem, demo_mem} =
  room_strokes
  |> Enum.zip(demo_strokes)
  |> Enum.with_index(1)
  |> Enum.reduce({room_mem, demo_mem}, fn {{rs, ds}, i}, {rm, dm} ->
    # The drawer's op rate limit (StrokeRules.op_rate_limit/0) is reset
    # between commits: it is not what is measured.
    if rem(i, 30) == 0,
      do: :sys.replace_state(room_pid, &%{&1 | stroke_rate_limits: %{}})

    :ok = RoomServer.append_drawing(room.id, drawer, rs)
    DemoBoardServer.add_stroke(ds)

    if i in [100, 300, 500] do
      demo_barrier.()
      :erlang.garbage_collect(room_pid)
      :erlang.garbage_collect(demo_pid)
      {Map.put(rm, i, Bench.mem(room_pid)), Map.put(dm, i, Bench.mem(demo_pid))}
    else
      {rm, dm}
    end
  end)

for k <- [0, 100, 300, 500] do
  Bench.log("  #{k}: room #{room_mem[k].total_bytes} B | demo #{demo_mem[k].total_bytes} B")
end

# What the board's ownership data (each stroke's owner and gesture, since
# #42) costs: the same 500 strokes held without those two keys.
held = :sys.get_state(demo_pid).strokes
set_demo.(Enum.map(held, &Map.drop(&1, [:owner, :gesture])))
:erlang.garbage_collect(demo_pid)
demo_without_ownership = Bench.mem(demo_pid)
set_demo.(held)
:erlang.garbage_collect(demo_pid)

Bench.log(
  "  demo 500 without owner/gesture: state #{demo_without_ownership.state_term_bytes} B " <>
    "(ownership #{demo_mem[500].state_term_bytes - demo_without_ownership.state_term_bytes} B of the state's " <>
    "#{demo_mem[500].state_term_bytes} B; binaries #{demo_without_ownership.binary_bytes} B)"
)

# The sets with fills, held by the room and the board (set directly, as
# stored; garbage-collected first).
set_room.(room_fill_strokes)
set_demo.(demo_fill_strokes)
:erlang.garbage_collect(room_pid)
:erlang.garbage_collect(demo_pid)
room_fills_mem = Bench.mem(room_pid)
demo_fills_mem = Bench.mem(demo_pid)
set_room.([])
set_demo.([])

Bench.log(
  "  500 with 50 fills: room #{room_fills_mem.total_bytes} B | demo #{demo_fills_mem.total_bytes} B"
)

results =
  Map.put(results, :memory, %{
    room: room_mem,
    demo: demo_mem,
    demo_500_without_ownership: demo_without_ownership,
    room_500_fills: room_fills_mem,
    demo_500_fills: demo_fills_mem
  })

# ── 4. What a joining viewer receives at 500 strokes ─────────────────────
Bench.log("join payloads at 500")
set_room.(room_strokes)
# The board filled through its own entry point, so its caps apply (since
# #44 it keeps at most 450,000 path bytes: not all 500 fixture strokes).
set_demo.([])
Enum.each(demo_strokes, &DemoBoardServer.add_stroke/1)
demo_kept = length(DemoBoardServer.get_strokes())
{:ok, view} = RoomServer.get_view(room.id, viewer)
500 = length(view.drawing_strokes)

view_time =
  Bench.sample(iterations, fn -> :ok end, fn _ ->
    {:ok, _} = RoomServer.get_view(room.id, viewer)
  end)
  |> Bench.stats()

encode_strokes = fn strokes -> Hologram.Compiler.Encoder.encode_term!(strokes) end

state_encode =
  Bench.sample(
    div(iterations, 4),
    fn -> :ok end,
    fn _ -> encode_strokes.(view.drawing_strokes) end,
    5
  )
  |> Bench.stats()

# The snapshot as DemoBoardChannel pushes it: the public fields of each
# stroke (a visitor with none of their own on the board: no `mine` flags).
snapshot_msg = fn strokes ->
  %Phoenix.Socket.Message{
    join_ref: "1",
    ref: nil,
    topic: "demo:board",
    event: "strokes",
    payload: %{
      strokes: Enum.map(strokes, &ScrawlyWeb.DemoBoardChannel.public_stroke(&1, "anon:viewer"))
    }
  }
end

encode_push = fn msg ->
  {:socket_push, :text, data} = Phoenix.Socket.V2.JSONSerializer.encode!(msg)
  data
end

snapshot_time =
  Bench.sample(
    div(iterations, 4),
    fn -> :ok end,
    fn _ ->
      DemoBoardServer.get_strokes() |> snapshot_msg.() |> encode_push.()
    end,
    5
  )
  |> Bench.stats()

snapshot_bytes =
  DemoBoardServer.get_strokes() |> snapshot_msg.() |> encode_push.() |> IO.iodata_length()

# Worst cases the caps allow: the demo board takes 500 strokes of 7,999
# bytes (no byte cap); the room stops at its 2,000,000-byte budget.
big_path = fn seed ->
  body =
    Stream.iterate(seed, &(&1 + 1))
    |> Stream.map(fn k ->
      " L #{rem(k * 7, 400)}.#{rem(k, 10)} #{rem(k * 13, 225)}.#{rem(k, 7)}"
    end)
    |> Enum.reduce_while("M 1 1", fn seg, acc ->
      if byte_size(acc) + byte_size(seg) > 7_999, do: {:halt, acc}, else: {:cont, acc <> seg}
    end)

  body <> String.duplicate(" ", 7_999 - byte_size(body))
end

big_demo =
  for k <- 1..500,
      do: %{
        path: big_path.(k),
        color: "#000000",
        width: 4,
        stroke_id: "big-#{k}",
        owner: "anon:bench",
        gesture: "big-#{k}"
      }

# Through the board's own entry point, so its caps apply (a byte cap since
# #44: it keeps only the newest strokes that fit).
set_demo.([])
Enum.each(big_demo, &DemoBoardServer.add_stroke/1)
big_kept = length(DemoBoardServer.get_strokes())

big_snapshot_time =
  Bench.sample(
    20,
    fn -> :ok end,
    fn _ -> DemoBoardServer.get_strokes() |> snapshot_msg.() |> encode_push.() end,
    3
  )
  |> Bench.stats()

big_snapshot_bytes =
  DemoBoardServer.get_strokes() |> snapshot_msg.() |> encode_push.() |> IO.iodata_length()

room_cap_count = div(StrokeRules.max_canvas_bytes(), 7_999)

big_room =
  for k <- 1..room_cap_count,
      do: %{id: "big-#{k}", path: big_path.(k), color: "#000000", width: 4}

set_room.(big_room)
{:ok, big_view} = RoomServer.get_view(room.id, viewer)

big_view_time =
  Bench.sample(50, fn -> :ok end, fn _ -> {:ok, _} = RoomServer.get_view(room.id, viewer) end, 5)
  |> Bench.stats()

# The same with the fills sets.
set_room.(room_fill_strokes)
set_demo.([])
Enum.each(demo_fill_strokes, &DemoBoardServer.add_stroke/1)
fills_kept = length(DemoBoardServer.get_strokes())
{:ok, fills_view} = RoomServer.get_view(room.id, viewer)
500 = length(fills_view.drawing_strokes)

fills_snapshot_bytes =
  DemoBoardServer.get_strokes() |> snapshot_msg.() |> encode_push.() |> IO.iodata_length()

join = %{
  room_view_500_fills: %{
    fills: Enum.count(fills_view.drawing_strokes, &StrokeRules.fill?/1),
    path_bytes: StrokeRules.canvas_bytes(fills_view.drawing_strokes),
    external_bytes: :erlang.external_size(fills_view),
    strokes_json_bytes: byte_size(Jason.encode!(fills_view.drawing_strokes)),
    strokes_hologram_state_bytes: byte_size(encode_strokes.(fills_view.drawing_strokes))
  },
  demo_snapshot_500_fills: %{bytes: fills_snapshot_bytes, strokes_kept: fills_kept},
  room_view_500: %{
    build: view_time,
    external_bytes: :erlang.external_size(view),
    strokes_json_bytes: byte_size(Jason.encode!(view.drawing_strokes)),
    strokes_hologram_state_bytes: byte_size(encode_strokes.(view.drawing_strokes)),
    strokes_hologram_state_encode: state_encode
  },
  demo_snapshot_500: %{build: snapshot_time, bytes: snapshot_bytes, strokes_kept: demo_kept},
  demo_snapshot_500_x_7999: %{
    build: big_snapshot_time,
    bytes: big_snapshot_bytes,
    strokes_kept: big_kept
  },
  room_view_at_byte_cap: %{
    strokes: room_cap_count,
    build: big_view_time,
    external_bytes: :erlang.external_size(big_view),
    strokes_hologram_state_bytes: byte_size(encode_strokes.(big_view.drawing_strokes))
  }
}

Bench.log(
  "  room view #{Bench.fmt(view_time)}, state #{join.room_view_500.strokes_hologram_state_bytes} B | " <>
    "demo snapshot #{snapshot_bytes} B #{Bench.fmt(snapshot_time)} | worst #{big_snapshot_bytes} B"
)

# What each viewer's SSE stream encodes per :stroke_completed (one encoding
# per connection).
sse_encode = fn path ->
  params = %{
    stroke_id: "s-abc-123",
    path: path,
    color: "#0a0a0a",
    width: 5,
    seq: 1_700_000_000_000_001
  }

  try do
    bytes =
      byte_size(
        Hologram.Realtime.SSE.encode_broadcast_envelope(1, :stroke_completed, params, ["page"])
      )

    time =
      Bench.sample(div(iterations, 2), fn -> :ok end, fn _ ->
        Hologram.Realtime.SSE.encode_broadcast_envelope(1, :stroke_completed, params, ["page"])
      end)
      |> Bench.stats()

    %{path_bytes: byte_size(path), event_bytes: bytes, encode: time}
  rescue
    e -> %{error: Exception.message(e)}
  end
end

long = Enum.max_by(game, &byte_size(&1.path))

join =
  Map.put(join, :sse_stroke_completed, %{
    medium: sse_encode.(probe.path),
    long: sse_encode.(long.path)
  })

results = Map.put(results, :join, join)
set_room.([])
set_demo.([])

# ── 5. Fan-out of live chunks ────────────────────────────────────────────
# One drawer pushes a chunk every 50 ms (20/s) to demo:board, relayed by
# DemoBoardChannel to every other visitor (the same broadcast_from fast lane
# GameChannel uses; a room has at most 12 players + 50 watchers). Deltas are
# 6-segment slices of a fixture scribble (~150 bytes, a fast stroke's 50 ms).
Bench.log("fan-out (clients in a peer node)")

deltas =
  long.path
  |> String.split(" Q ")
  |> tl()
  |> Enum.chunk_every(6)
  |> Enum.map(&(" Q " <> Enum.join(&1, " Q ")))

{:ok, peer, _node} =
  :peer.start_link(%{
    connection: :standard_io,
    args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
  })

{:module, Bench.WS} = :peer.call(peer, :code, :load_binary, [ws_mod, ~c"bench_ws", ws_bin])
{:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:crypto])

top_queue = fn ->
  Process.list()
  |> Enum.reduce({0, nil}, fn pid, {max, who} ->
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when len > max -> {len, pid}
      _ -> {max, who}
    end
  end)
end

describe = fn
  nil ->
    nil

  pid ->
    case Process.info(pid, [:registered_name, :dictionary, :current_function]) do
      nil ->
        "exited"

      info ->
        name = info[:registered_name]
        initial = get_in(info, [:dictionary, :"$initial_call"])

        cond do
          name not in [nil, []] -> inspect(name)
          initial -> inspect(initial)
          true -> inspect(info[:current_function])
        end
    end
end

# Samples the longest mailbox every 25 ms until told to stop.
sampler = fn ->
  me = self()

  spawn(fn ->
    loop = fn loop, best ->
      receive do
        {:stop, from} -> send(from, {:sampled, me, best})
      after
        25 ->
          {len, pid} = top_queue.()
          best = if len > elem(best, 0), do: {len, describe.(pid)}, else: best
          loop.(loop, best)
      end
    end

    loop.(loop, {0, nil})
  end)
end

stop_sampler = fn pid ->
  send(pid, {:stop, self()})

  receive do
    {:sampled, _, best} -> best
  end
end

utilization = fn ms ->
  s0 = :scheduler.sample_all()
  Process.sleep(ms)
  s1 = :scheduler.sample_all()
  {:total, total, _} = List.keyfind(:scheduler.utilization(s0, s1), :total, 0)
  total
end

send_ms = 6_000
interval_ms = 50
undos = 40
undo_interval_ms = 50

# The board's snapshot as a joining visitor gets it, on the wire (smaller
# when the socket compresses).
set_demo.([])
Enum.each(demo_strokes, &DemoBoardServer.add_stroke/1)
snapshot_wire = :peer.call(peer, Bench.WS, :snapshot_probe, [ws_port], 30_000)
set_demo.([])
Bench.log("  snapshot on the wire: #{inspect(snapshot_wire)}")

fanout =
  for subs <- [10, 50, 200], into: %{} do
    :erlang.garbage_collect()
    mem_before = :erlang.memory(:total)
    ^subs = :peer.call(peer, Bench.WS, :start_subscribers, [ws_port, subs], 60_000)
    Process.sleep(500)
    # The server's memory per connected visitor (their socket and channel
    # processes, and with compression each socket's zlib streams).
    mem_per_subscriber = div(:erlang.memory(:total) - mem_before, subs)

    idle_sampler = sampler.()
    idle = utilization.(2_000)
    {idle_queue, _} = stop_sampler.(idle_sampler)

    busy_sampler = sampler.()

    task =
      Task.async(fn ->
        :peer.call(
          peer,
          Bench.WS,
          :run_sender,
          [ws_port, board_token, deltas, interval_ms, send_ms],
          send_ms + 20_000
        )
      end)

    Process.sleep(500)
    busy = utilization.(send_ms - 1_000)
    sent = Task.await(task, send_ms + 25_000)
    {max_queue, queue_owner} = stop_sampler.(busy_sampler)
    Process.sleep(300)

    reports = :peer.call(peer, Bench.WS, :collect, [], 30_000)

    # A board undo with this many visitors connected: the board holds the
    # 500 demo strokes, all of one owner, one gesture each; that owner undoes
    # one every 50 ms. Timed: the undo call (DemoBoardServer.undo/1, its
    # broadcast included), scheduler use meanwhile, and each visitor's
    # receipt of its `stroke_removed` push (OS clock, same machine).
    set_demo.(demo_strokes)
    _ = :peer.call(peer, Bench.WS, :collect, [], 30_000)
    undo_sampler = sampler.()
    s0 = :scheduler.sample_all()

    undo_marks =
      for _ <- 1..undos do
        sent_at = System.os_time(:microsecond)
        t0 = Bench.now_ns()
        {:ok, [_id]} = DemoBoardServer.undo("anon:bench")
        call_us = (Bench.now_ns() - t0) / 1000
        Process.sleep(undo_interval_ms)
        {sent_at, call_us}
      end

    s1 = :scheduler.sample_all()
    {undo_queue, undo_queue_owner} = stop_sampler.(undo_sampler)
    {:total, undo_util, _} = List.keyfind(:scheduler.utilization(s0, s1), :total, 0)
    Process.sleep(300)
    undo_reports = :peer.call(peer, Bench.WS, :collect, [], 30_000)
    sent_ats = Enum.map(undo_marks, &elem(&1, 0))

    undo_lat =
      undo_reports
      |> Enum.flat_map(fn r -> r.removed |> Enum.zip(sent_ats) |> Enum.map(fn {at, sent} -> (at - sent) / 1000 end) end)
      |> Enum.sort()

    undo_row = %{
      undos: undos,
      interval_ms: undo_interval_ms,
      call: undo_marks |> Enum.map(&elem(&1, 1)) |> Bench.stats(),
      pushes_delivered: length(undo_lat),
      delivered_ratio: Float.round(length(undo_lat) / (undos * subs), 4),
      scheduler_utilization_pct: Float.round(undo_util * 100, 2),
      longest_message_queue: undo_queue,
      longest_message_queue_owner: undo_queue_owner,
      delivery_latency_ms:
        if(undo_lat == [],
          do: nil,
          else: %{
            median: Float.round(Bench.pct(undo_lat, 50), 3),
            p95: Float.round(Bench.pct(undo_lat, 95), 3),
            max: Float.round(List.last(undo_lat), 3)
          }
        )
    }

    set_demo.([])

    Bench.log(
      "  #{subs} subscribers, board undo: call #{Bench.fmt(undo_row.call)}, util #{undo_row.scheduler_utilization_pct}%, " <>
        "delivered #{undo_row.pushes_delivered}/#{undos * subs}, latency #{inspect(undo_row.delivery_latency_ms)}"
    )

    :ok = :peer.call(peer, Bench.WS, :stop_subscribers, [])
    lat = reports |> Enum.flat_map(& &1.lat) |> Enum.map(&(&1 / 1000))
    received = reports |> Enum.map(&length(&1.lat)) |> Enum.sum()
    payload_bytes = reports |> Enum.map(& &1.bytes) |> Enum.sum()
    wire_bytes = reports |> Enum.map(& &1.wire) |> Enum.sum()
    lat_sorted = Enum.sort(lat)
    schedulers = System.schedulers_online()
    extra = max(busy - idle, 0.0)
    # Scheduler-busy microseconds the server spends per delivered chunk: the
    # busy time above idle over the window, against the deliveries made in
    # that window (received spread evenly over send_ms).
    us_per_delivery =
      if received > 0, do: extra * schedulers * send_ms * 1000 / received, else: nil

    row = %{
      subscribers: subs,
      chunks_sent: sent,
      chunks_delivered: received,
      server_memory_per_subscriber_bytes: mem_per_subscriber,
      payload_bytes: payload_bytes,
      wire_bytes: wire_bytes,
      delivered_ratio: if(sent > 0, do: Float.round(received / (sent * subs), 4), else: 0.0),
      scheduler_utilization_idle_pct: Float.round(idle * 100, 2),
      scheduler_utilization_pct: Float.round(busy * 100, 2),
      server_us_per_delivered_chunk: us_per_delivery && Float.round(us_per_delivery, 2),
      longest_message_queue: max_queue,
      longest_message_queue_owner: queue_owner,
      longest_message_queue_idle: idle_queue,
      delivery_latency_ms:
        if(lat_sorted == [],
          do: nil,
          else: %{
            median: Float.round(Bench.pct(lat_sorted, 50), 3),
            p95: Float.round(Bench.pct(lat_sorted, 95), 3),
            max: Float.round(List.last(lat_sorted), 3)
          }
        ),
      board_undo: undo_row
    }

    Bench.log(
      "  #{subs} subscribers: util #{row.scheduler_utilization_pct}% (idle #{row.scheduler_utilization_idle_pct}%), " <>
        "delivered #{received}/#{sent * subs}, max queue #{max_queue} (#{queue_owner}), " <>
        "#{mem_per_subscriber} B/visitor, wire #{wire_bytes}/#{payload_bytes} B, " <>
        "latency #{inspect(row.delivery_latency_ms)}"
    )

    {subs, row}
  end

:peer.stop(peer)

results =
  results
  |> Map.put(:fanout, %{
    deflate_offered: System.get_env("BENCH_WS_DEFLATE") == "1",
    snapshot_wire: snapshot_wire,
    chunk_interval_ms: interval_ms,
    send_ms: send_ms,
    delta_bytes_avg: div(Enum.sum(Enum.map(deltas, &byte_size/1)), length(deltas)),
    runs: fanout
  })
  |> put_in([:meta, :duration_s], div(System.monotonic_time(:millisecond) - t_start, 1000))

# Leave nothing running: stop the room (its DB rows go with the sandbox).
DynamicSupervisor.terminate_child(Scrawly.RoomSupervisor, room_pid)
set_demo.([])

File.mkdir_p!(Path.dirname(out_path))
File.write!(out_path, Jason.encode_to_iodata!(results, pretty: true))
Bench.log("wrote #{out_path} (#{results.meta.duration_s} s)")
