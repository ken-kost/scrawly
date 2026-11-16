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

    %{
      process_bytes: memory,
      heap_bytes: heap_words * :erlang.system_info(:wordsize),
      binary_bytes: bin_bytes,
      binary_count: length(Enum.uniq_by(bins, &elem(&1, 0))),
      total_bytes: memory + bin_bytes
    }
  end

  def load_fixture(name) do
    path = Path.expand("fixtures/#{name}.json", __DIR__)
    %{"strokes" => strokes} = path |> File.read!() |> Jason.decode!()

    Enum.map(strokes, fn s ->
      %{
        id: :binary.copy(s["id"]),
        path: :binary.copy(s["path"]),
        color: :binary.copy(s["color"]),
        width: s["width"],
        kind: s["kind"]
      }
    end)
  end
end

# A minimal WebSocket client (RFC 6455, text frames only), loaded into the
# :peer node that plays the visitors' browsers.
{:module, ws_mod, ws_bin, _} =
  defmodule Bench.WS do
    @moduledoc false

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
            "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
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

    # Complete server frames (unmasked) from `buf`: {[payload], rest}.
    def frames(buf, acc \\ []) do
      case buf do
        <<_fin::1, _::3, _op::4, 0::1, 127::7, len::64, payload::binary-size(len), rest::binary>> ->
          frames(rest, [payload | acc])

        <<_fin::1, _::3, _op::4, 0::1, 126::7, len::16, payload::binary-size(len), rest::binary>> ->
          frames(rest, [payload | acc])

        <<_fin::1, _::3, _op::4, 0::1, len::7, payload::binary-size(len), rest::binary>>
        when len < 126 ->
          frames(rest, [payload | acc])

        _ ->
          {Enum.reverse(acc), buf}
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
      sub_loop(sock, rest, %{lat: [], frames: 0, bytes: 0})
    end

    defp sub_loop(sock, buf, st) do
      receive do
        {:tcp, ^sock, data} ->
          now = System.os_time(:microsecond)
          {payloads, rest} = frames(buf <> data)

          st =
            Enum.reduce(payloads, st, fn p, st ->
              st = %{st | frames: st.frames + 1, bytes: st.bytes + byte_size(p)}

              case :binary.match(p, "\"stroke_chunk\"") do
                :nomatch ->
                  st

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
          send(from, {:report, self(), st})
          sub_loop(sock, buf, %{st | lat: [], frames: 0, bytes: 0})

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
          10_000 -> %{lat: [], frames: 0, bytes: 0}
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

set_demo = fn strokes ->
  :sys.replace_state(demo_pid, fn s -> %{s | strokes: strokes} end)
  :ok
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
    demo_prefix = Enum.take(demo_strokes, held)

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

    Bench.log("  #{held}: room #{Bench.fmt(room_stats)} | demo #{Bench.fmt(demo_stats)}")

    {held,
     %{room: room_stats, demo: demo_stats, room_check_append: check, room_list_append: append}}
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

results = Map.put(results, :memory, %{room: room_mem, demo: demo_mem})

# ── 4. What a joining viewer receives at 500 strokes ─────────────────────
Bench.log("join payloads at 500")
set_room.(room_strokes)
set_demo.(demo_strokes)
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

set_demo.(big_demo)

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

join = %{
  room_view_500: %{
    build: view_time,
    external_bytes: :erlang.external_size(view),
    strokes_json_bytes: byte_size(Jason.encode!(view.drawing_strokes)),
    strokes_hologram_state_bytes: byte_size(encode_strokes.(view.drawing_strokes)),
    strokes_hologram_state_encode: state_encode
  },
  demo_snapshot_500: %{build: snapshot_time, bytes: snapshot_bytes},
  demo_snapshot_500_x_7999: %{build: big_snapshot_time, bytes: big_snapshot_bytes},
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

fanout =
  for subs <- [10, 50, 200], into: %{} do
    ^subs = :peer.call(peer, Bench.WS, :start_subscribers, [ws_port, subs], 60_000)
    Process.sleep(500)

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
    :ok = :peer.call(peer, Bench.WS, :stop_subscribers, [])
    lat = reports |> Enum.flat_map(& &1.lat) |> Enum.map(&(&1 / 1000))
    received = reports |> Enum.map(&length(&1.lat)) |> Enum.sum()
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
        )
    }

    Bench.log(
      "  #{subs} subscribers: util #{row.scheduler_utilization_pct}% (idle #{row.scheduler_utilization_idle_pct}%), " <>
        "delivered #{received}/#{sent * subs}, max queue #{max_queue} (#{queue_owner}), " <>
        "latency #{inspect(row.delivery_latency_ms)}"
    )

    {subs, row}
  end

:peer.stop(peer)

results =
  results
  |> Map.put(:fanout, %{
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
