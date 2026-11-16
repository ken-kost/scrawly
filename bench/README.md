# Drawing benchmarks

Two benchmarks of the drawing paths, and the fixtures they share. The
numbers, budgets and findings are in `notes/files/drawing-benchmarks.md`.
They measure only: nothing here changes the app, and they are too slow and
too noisy for CI.

| file | what |
|---|---|
| `fixtures/{game,demo}-{100,300,500}.json` | stroke sets for the in-game canvas and the demo board (both 800x450 since #37; the baseline runs in `results/` had the board at 400x225) |
| `fixtures/generate.mjs` | writes them (`--check` verifies the stored files) |
| `fixtures/{game,demo}-fills-{100,300,500}.json` | the same sets with every tenth stroke a fill (#44) |
| `fixtures/generate_fills.mjs` | writes them with the fill tool's own worker, in headless Chromium (`--check` too) |
| `lib/fixture_gen.mjs` | the generator: synthetic pointer points through the app's own `createStrokeBuilder` |
| `drawing_server.exs` | server benchmark (`mix run`, test env, scratch database) |
| `drawing_client.mjs` | client benchmark (headless Chromium against a local prod build) |
| `prod_server.sh` | builds and runs that prod build (scratch folder, port and database) |
| `lib/bench_rpc.exs`, `lib/page_probe.js` | the client benchmark's server-side setup and in-page probe |
| `own_layer.mjs` | the experiment behind the rendering decision (committed strokes in their own layer; #44 made that split in the app, so on today's board it splits an already split canvas) |
| `compare.mjs` | compares the medians of two runs |
| `table.mjs` | the headline figures of several runs side by side (Markdown) |
| `results/` | the runs the report quotes: #36's baseline (`*-run{1,2}`), #44's "after features" (`*-after-features`) and final (`*-final`) |

## Fixtures

Seeded and deterministic: stroke *i* of a canvas depends only on the canvas
and *i*, so the 100- and 300-stroke sets are the first 100 and 300 strokes of
the 500 set, and the client benchmark regenerates a stroke's points to replay
it as a gesture. Mix by count: 45% short (~300 bytes), 30% medium (~1.5 KB),
10% long scribbles (3-7 KB, under the engine's 7,000-character split), 15%
white eraser strokes. The 500 sets hold ~620 KB of path data (the room's
budget is 2 MB). Every stroke passes `StrokeRules.check_append/2` (the server
benchmark checks).

    node bench/fixtures/generate.mjs --check

The sets with fills (#44): the line set of the same canvas with stroke 9,
19, 29, ... replaced by a fill, the area the fill tool works out
(`priv/static/fill_worker.mjs`, run in headless Chromium) for a press at a
seeded point over the strokes before it, in a seeded colour (a press that
fills nothing or too detailed an area tries the next point). 10 / 30 / 50
fills, ~734 KB of path data at 500. The worker rasters with Chromium, so
`--check` needs the same Chromium build:

    PLAYWRIGHT=... CHROME=... node bench/fixtures/generate_fills.mjs --check

## Requirements

- The project's toolchain (Elixir 1.19 / OTP 28, as in the `Dockerfile`).
  On the dev machine: `source /tmp/holo_research/t12/newtc.sh` first.
- PostgreSQL on localhost (`postgres`/`postgres`; see `BENCH_PG` in
  `prod_server.sh`), with `psql`, `createdb`, `dropdb`.
- Node 20+ and Playwright with Chromium. Any Playwright 1.4x+ works:
  `npm i -D playwright && npx playwright install chromium` in a scratch
  folder, then point `PLAYWRIGHT` at its `node_modules/playwright/index.mjs`.
  On the dev machine:

      export PLAYWRIGHT=/home/ken/.npm/_npx/e41f203b7505f1fb/node_modules/playwright/index.mjs
      export CHROME=$HOME/.cache/ms-playwright/chromium-1181/chrome-linux/chrome

## Server benchmark

Test environment, its own scratch database (`scrawly_test_bench`), all of it
inside one SQL sandbox transaction that is rolled back. The endpoint listens
on `BENCH_WS_PORT` (default 4199) for the fan-out part only. ~30 s.

    MIX_TEST_PARTITION=_bench MIX_ENV=test mix ash.setup --quiet      # once
    MIX_TEST_PARTITION=_bench MIX_ENV=test mix run --no-start bench/drawing_server.exs [OUT.json]
    MIX_TEST_PARTITION=_bench MIX_ENV=test mix ecto.drop             # when done

`BENCH_ITERATIONS` (default 400) sets the samples per timing.
`BENCH_WS_DEFLATE=1` makes the fan-out's visitors offer permessage-deflate
(as browsers do), so a socket configured with `compress: true` compresses
(#44's compression trial). Output (default
`bench/results/server-<date>.json`), all times in microseconds:

- `commit`: `RoomServer.append_drawing/3` (a GenServer call: validation,
  limits, append, publish) and `DemoBoardServer.add_stroke/1` (a cast plus a
  `:sys` round trip, `demo_barrier_round_trip`), with 0/100/300/499 strokes
  held; `room_check_append` and `room_list_append` time
  `StrokeRules.check_append/2` and `strokes ++ [stroke]` alone, and
  `room_check_with_totals` the same check with the count and bytes kept
  in the state (validation plus two comparisons). Since #44 the board's
  strokes are capped at 450,000 path bytes: `demo_strokes_held` is what it
  holds for each count.
- `at_500`: undo (by id) and clear with 500 strokes held.
- `memory`: the room process and the demo board process after a GC, holding
  0/100/300/500 strokes committed through their real entry points.
  `process_bytes` is `:erlang.process_info(pid, :memory)`; `binary_bytes` the
  refc binaries it references (`:binary`), each counted once and in full;
  `state_term_bytes` the state's own flat size (unlike the heap, not moved
  by the heap's allocation steps). `demo_500_without_ownership`: the
  board's state without each stroke's owner and gesture (#42), i.e. what
  that ownership data costs; `room_500_fills`, `demo_500_fills`: the sets
  with fills.
- `join`: what a joining viewer gets at 500 strokes: `RoomServer.get_view/2`
  (time, `:erlang.external_size/1`, the strokes as JSON and as Hologram's page
  state encoding, and the time of that encoding); the demo board's `"strokes"`
  push as the socket sends it (Phoenix V2 JSON), the board filled through
  `DemoBoardServer.add_stroke/1` (its caps apply), also for 500 strokes of
  7,999 bytes (the byte cap keeps 56) and for the room at its 2 MB cap;
  the same for the sets with fills (`*_fills`);
  `sse_stroke_completed`: what each viewer's SSE stream encodes per
  `:stroke_completed` (per connection: N viewers, N encodings).
- `fanout`: one drawer pushing a ~150-byte chunk every 50 ms to `demo:board`
  for 6 s, relayed to 10/50/200 other visitors (real WebSocket clients in a
  separate `:peer` node, so the scheduler figures count the server only):
  scheduler utilization (all schedulers, `:scheduler.utilization/2`) idle
  and while relaying, server CPU per delivered chunk, the longest mailbox seen
  (sampled every 25 ms) and its owner, and delivery latency (send to client
  receipt). GameChannel relays through the same `broadcast_from` fast lane; a
  room has at most 12 players and 50 watchers. Per run also the server's
  memory per connected visitor, the bytes on the wire against the payload
  bytes, the board's snapshot as a joining visitor gets it on the wire
  (`snapshot_wire`), and `board_undo`: with the visitors connected, the
  board's owner undoes 40 strokes 50 ms apart (the call, scheduler use,
  each visitor's receipt of `stroke_removed`).

How it gets its numbers: the room is a real BENCH room in `:drawing` whose
round timers are cancelled (no time-up, no hint reveals). Between samples it
puts the held strokes back with `:sys.replace_state/2` (untimed) and resets
the drawer's op rate limit, which is not what is measured.

## Client benchmark

1. Build and start the local prod release (scratch folder
   `BENCH_DIR=/tmp/scrawly-bench`, port `BENCH_PORT=4100`, database
   `BENCH_DB=scrawly_bench`; nothing of the dev build or database is used):

       bench/prod_server.sh build     # ~5 min from scratch, ~1 min after
       bench/prod_server.sh start

   `BENCH_SEED=<folder with deps/ and _build/ of an earlier prod build>`
   skips the dependency build on the first `build`. Without
   `MIX_ENV=prod HOLOGRAM_ENV=prod` (the script sets them) a release has
   Hologram disabled and every page 404s.

2. Run (~22 min; `--quick` for a smoke run of ~4 min):

       node bench/drawing_client.mjs [--out FILE] [--only GROUPS] [--sizes 0,300] [--rates 1]

   `--only` takes any of `drawer,tools,demo,viewer,fills,leak,leak_tools`
   (the drawer page is loaded for `tools` and `viewer` too). A phase that
   fails is logged and recorded under `errors`, and the run goes on; the
   results file is written after every phase.

   With the server benchmark (~30 s) that is under 10 minutes for both. The
   rendering experiment, separately (it reloads the demo board, so not while
   the client benchmark runs):

       N=500 node bench/own_layer.mjs

3. Clean up: `bench/prod_server.sh clean` (stops the release, drops the
   database, deletes the scratch folder).

Setup goes through `bench/prod_server.sh rpc` (`lib/bench_rpc.exs`): two
registered BENCH users, a room, a game in `:drawing` with its round timers
cancelled. Each canvas size is loaded through `RoomServer.append_drawing/3`
and `DemoBoardServer.add_stroke/1` while no page is open. Three headless
Chromium processes (one per page: pages of one browser share its frame
production and slow each other down): the drawer and a viewer, both signed in
on the game page, and an anonymous visitor on the home page; each page is
loaded twice, unmeasured, first (a fresh browser's first loads are slower).
CPU throttling is `Emulation.setCPUThrottlingRate` (rate 4) on each page's
CDP session; it doesn't slow raster threads.

The probe (`lib/page_probe.js`, injected before the page's scripts) counts
Hologram's actions by name (`actions`), stamps
each Realtime broadcast when its SSE event arrives and each demo board push
when its WebSocket frame arrives, records a per-frame timeline of the
canvases' stroke counts during a load, times frames (`requestAnimationFrame`
starts, and per frame the time from the first rAF callback to the end of its
rendering, via a `MessageChannel` message), and dispatches native
`PointerEvent`s for gestures. Hologram 0.12 `console.log`s every render,
action and (during an action) every compiled function call, in prod too; the
probe drops those messages, which a visitor without DevTools never ships to a
debugger (`viewer_apply_with_console_logs` measures them once).

The layout's decorative glows (`.nav-glow`, `.footer-glow`: animated
`blur(40px)` / `blur(90px)` layers) are hidden on every page once Hologram has
mounted (inline `display: none`; the mount's own patch would undo it
earlier). Headless Chromium composites in software, where the footer glow,
visible under the short game page, costs 35-42 ms a frame and caps that page
at 20-30 fps, which would hide the canvas's own cost. `drawer_draw_with_glow`
measures the page with them (0 and 500 strokes, 1x).

Output (default `bench/results/client-<date>.json`), `runs.<rate>.<strokes>`,
times in ms:

- `drawer_draw`, `demo_draw`: four 300-move gestures (a scribble over the
  whole canvas, one move every 8 ms, i.e. 2.4 s, split once by the engine's
  7,000-character limit), each traced (Chromium trace categories `cc,viz`).
  Per frame produced (a gesture's total over its frames, median of the
  gestures): `main_thread_ms_per_frame` (`ProxyMain::BeginMainFrame`: rAF
  callbacks, style, layout, paint, commit), `raster_ms_per_frame`
  (`RasterTask`, all raster workers), `compositor_ms_per_frame` (the display
  compositor's `Display::DrawAndSwap`). In `frame_aligned`: `frame_ms`, the
  interval between frames; `frames_over_16_7`, frames longer than one 60 Hz
  slot (interval > 17.7 ms); `idle`, the same page's share of long frames
  with nothing happening (headless Chromium misses a few even then);
  `frame_work_ms`, each frame from its first rAF callback to the end of its
  rendering as the page sees it (tasks queued in between count too).
- `drawer_load`, `demo_load`, `viewer_load`: navigation to the end of the
  first frame showing every stroke (`painted_ms`; one load for the drawer,
  four for the others); for the viewer, `data_to_paint_ms` from the HTML's
  last byte to it; for the demo board, `data_to_paint_ms` is the snapshot's
  handling (Phoenix's `onmessage` down to `demo_board.mjs` building the
  canvas) plus that first frame's rendering, with the handling alone and the
  wall clock, all in `during_load` (they share the main thread with the
  page's boot); `demo_snapshot` takes the same snapshot again on the idle
  page, five times, by reconnecting its socket (`handler_ms`, `paint_ms`);
  `thresholded.long_tasks_ms` / `busy_until_ms`: main thread
  time in tasks over 50 ms in the first 15 s, and when the last one ended;
  `html_bytes` (decoded) / `html_transfer_bytes` (gzip) / `snapshot_bytes`.
- `viewer_apply`: a medium fixture stroke replayed on the drawer page as a
  gesture (op queue, `complete_stroke`, the room's broadcast), timed on the
  viewer from its SSE event to the new path in the DOM (`dom_ms`), and that
  plus the rendering of the next frame (`paint_ms`: the main-thread cost of
  showing it, without the wait for the frame; wall clock in
  `frame_aligned.wall_paint_ms`); `thresholded`: long tasks in between;
  `sse_handler_ms`: Hologram's decoding of the event; `hologram_logs_per_apply`.
  At 500 the drawer first undoes one stroke (the room is full), so the stroke
  applied is the 500th.
- `viewer_undo`, `drawer_undo`: the drawer's Ctrl+Z, timed on the drawer from
  keydown, and on the viewer from its `:drawing_undone` event.
- `viewer_idle_busy_ms_per_s`: main-thread time per second of an idle viewer
  page (its countdown re-renders every second), from one 2 s window: a single
  figure, not a median, and it moves by up to a third between runs.
- `*_memory` (1x): the page loaded with the strokes in a new browser context
  (same sign-in, a renderer process of its own: pages loaded one after
  another in one tab can share a V8 isolate with earlier documents' leftovers),
  after a forced GC: JS heap, live DOM nodes (`dom_nodes`, detached ones
  included) and the nodes in the document's tree (`document_nodes`). The
  back/forward cache is off in all three browsers.
- `leak`: at 1x, the room (100 strokes, committed one by one) and the demo
  board (500) are cleared and refilled 20 times while the three pages stay
  open; heap and nodes after a first cycle, after 10 more, after 20 more.
- The tools (#38-#43, `tools`, on the drawer's canvas at every size and
  rate): `drawer_hover`, the size ring following 300 mouse moves with no
  button (traced like a gesture); `drawer_pick`, ten Alt+clicks (the
  eyedropper's quick pick): the pointerdown handler and that plus the next
  frame; `drawer_fill`, four fills at the canvas's corner (`background`,
  the white around the drawing) and at its centre, each undone: pointerdown
  to the frame after the shape's node, the main thread's and the fill
  worker's busy time in that window (a trace); `drawer_slider_drag`,
  `drawer_wheel_drag`, a one-second real mouse drag (CDP input, 60 moves)
  on the size slider and on the colour wheel, traced, with the Hologram
  actions they ran. At 500 the drawer first undoes one stroke (a full
  canvas takes no fill) and draws it back after.
- `runs_fills` (`fills`): the drawer, demo board and viewer scenarios with
  the sets with fills, at 500 strokes.
- `leak_tools` (#44): 20 rounds in which the drawer (game) and a visitor
  (board) each use every tool (three strokes, a Ctrl and a right-button
  stroke, an Alt+click pick, the size keys, a pick on the colour wheel, a
  fill, Ctrl+Z, the toolbar's clear; a board clear is retried after
  DemoBoardChannel's 5 s limit), the viewer following; heap and nodes
  after 1, 11 and 21 rounds.

## Reading two runs

    node bench/compare.mjs bench/results/client-a.json bench/results/client-b.json
    node bench/compare.mjs bench/results/server-a.json bench/results/server-b.json --all

For the headline figures of several runs side by side (the report's
tables):

    node bench/table.mjs bench/results/client-run1.json bench/results/client-after-features.json bench/results/client-final.json

`compare.mjs` lists every median that moved more than 15% (`--tolerance`), ignoring
medians under 1 (`--floor`: in ms results a sub-millisecond median is a few
steps of the browser's 0.1 ms timer), and exits 1 if there is any. Medians are what the agreement
rule is about; p95s and maxima of a few dozen samples move more.

Three groups are reported but not compared: `frame_aligned` (figures tied
to the 60 Hz frame clock: frame intervals come in steps of 16.7 ms, and a
latency that includes the wait for the next frame moves by up to a frame
with its phase), `thresholded` (sums of tasks over 50 ms: a task just under
or over the line moves them by its whole length) and `during_load` (the demo
board's snapshot costs while the page boots). Each has a compared
counterpart that measures the same cost without the clock, the threshold or
the boot: `main_thread_ms_per_frame` / `raster_ms_per_frame`, `paint_ms`,
`data_to_paint_ms`, `demo_snapshot`.

Machine noise matters: close other heavy processes, keep the laptop on mains
power, and don't run the two benchmarks at the same time.
