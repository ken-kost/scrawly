# Drawing benchmarks: baseline, budgets and the rendering decision

Task #36 (`draw-bench`). How to run and how each number is taken:
`bench/README.md`. Raw results: `bench/results/{server,client}-run{1,2}.json`.
Baseline for `draw-optimize` (#44); measured before the drawing features
(#37-#43) land.

## Setup

- Machine: Intel Core i9-11950H (8 cores / 16 threads, 2.6 GHz), 16 GB, WSL2
  (Linux 6.18). Headless Chromium has no GPU here: it rasterizes and
  composites in software, on worker threads.
- Software: Erlang/OTP 28.3.3, Elixir 1.19.7, Hologram 0.12.8, Chromium
  (Playwright build 1181), Node 23.6. Date: 2026-11-15.
- Code: commit 34b8cec (branch `drawing-tools`); the app code is unchanged.
- Server benchmark: test env, scratch DB `scrawly_test_bench`, 400 samples
  per timing.
- Client benchmark: a prod `mix release` of the same tree on :4100 against
  the scratch DB `scrawly_bench`; 1280x900 pages; 1x and 4x CPU
  (`Emulation.setCPUThrottlingRate`).

## Server results

Times are median / p95 in microseconds (run 2's median in brackets).

### Commit, undo, clear

| strokes held | room commit | demo board commit | `check_append` alone | `strokes ++ [s]` alone |
|---|---|---|---|---|
| 0 | 11.6 / 17.8 (11.3) | 3.2 / 5.5 (3.2) | 5.9 / 7.8 | 0.03 |
| 100 | 14.3 / 19.6 (13.1) | 3.6 / 3.8 (3.6) | 7.1 / 11.0 | 0.2 |
| 300 | 20.6 / 32.0 (20.0) | 4.5 / 7.3 (4.6) | 8.8 / 9.7 | 0.4 |
| 499 | 27.1 / 40.9 (27.0) | 4.9 / 9.3 (5.0) | 10.6 / 11.7 | 0.7 |

Room commit = `RoomServer.append_drawing/3`, a GenServer call (authorize,
rate slot, stale-op and id checks, `check_append`, append, publish). Demo
commit = `DemoBoardServer.add_stroke/1` plus a 1.2 us `:sys` round trip.
With 500 strokes: room undo 16.7 / 25.8 (16.6), room clear 5.9 / 16.1 (5.9),
demo clear 3.2 / 6.2 (3.3).

The O(n) work (`length/1`, `canvas_bytes/1`, the duplicate-id scan, `++`)
adds ~15 us at 499 strokes. Not worth optimising on its own.

### Process memory (after GC)

| strokes | room: process / binaries | demo board: process / binaries |
|---|---|---|
| 0 | 9 KB / 0 | 3 KB / 0 |
| 100 | 35-89 KB / 114 KB | 34 KB / 115 KB |
| 300 | 143 KB / 347 KB | 89 KB / 363 KB |
| 500 | 231 KB / 620 KB | 143 KB / 615 KB |

Binaries are exactly the path bytes (one refc binary per path); the process
heap adds ~280-460 bytes per stroke (the range is the heap's allocation step
after GC, which differed between runs). A full room is ~0.85 MB, a full demo
board ~0.76 MB.

### What a joining viewer receives (500 strokes)

| payload | size | build time |
|---|---|---|
| room view (`RoomServer.get_view/2`) | 654 KB (external term) | 53 us |
| its strokes as Hologram page state (`Encoder.encode_term!/1`) | 717 KB | 5.3 ms |
| demo board `"strokes"` push (Phoenix V2 JSON) | 648 KB | 1.7 ms |
| demo board push, 500 strokes of 7,999 bytes (no byte cap) | 4.03 MB | 9.1 ms |
| room at its 2 MB cap (250 strokes of 7,999 bytes), page state | 2.05 MB | 29 us (view) |
| one `:stroke_completed` SSE event, medium (1.8 KB) / long (6.9 KB) path | 2.2 KB / 7.3 KB | 17 us / 38 us per viewer |

The game page HTML carries the strokes twice (page state and rendered
`<path>`s): see the client loads below.

### Live chunk fan-out (20 chunks/s, ~145-byte deltas, demo:board)

| subscribers | scheduler use (idle) | server CPU per delivered chunk | longest mailbox | delivery latency median / p95 / max |
|---|---|---|---|---|
| 10 | 0.15% (0.12%) | 21 us | 1 | 1.4 / 1.8 / 2.1 ms |
| 50 | 0.23% (0.13%) | 18 us | 1 | 1.7 / 2.2 / 2.6 ms |
| 200 | 0.72% (0.13%) | 24 us | 1 (5 in run 2, a DB pool) | 2.5 / 3.5 / 5.4 ms |

All chunks delivered. Scheduler use is the average over 16 schedulers.
GameChannel relays through the same `broadcast_from` fast lane; a room has at
most 12 players and 50 watchers.

Run agreement (server): 30 medians, all within 8.4% (`node bench/compare.mjs
bench/results/server-run1.json bench/results/server-run2.json`).

## Client results

Medians / p95 in ms, run 2's median in brackets. "Painted" figures are the
main-thread cost of getting a change on screen (the DOM change plus the
rendering of the frame that shows it), without the wait for that frame.
Raster is not slowed by the CPU throttling (it runs on raster worker
threads, which `Emulation.setCPUThrottlingRate` leaves alone), so the 4x rows
carry desktop raster times.

### Drawing: a 300-move gesture

Main thread, raster and compositor: ms per frame produced (from a trace,
median of the four gestures). The last three columns are frame-aligned (not
compared).

| canvas | strokes | rate | main thread per frame | raster per frame | compositor per frame | frame work p95 (rAF to rendered) | frame interval p50 / p95 | frames over 16.7 ms (idle) |
|---|---|---|---|---|---|---|---|---|
| drawer | 0 | 1x | 0.74 (0.61) | 1.2 (1.1) | 0.75 (0.67) | 0.9 | 16.7 / 16.8 | 0% (0%) |
| drawer | 100 | 1x | 0.70 (0.65) | 7.4 (7.4) | 0.72 (0.67) | 0.9 | 16.7 / 16.7 | 0% (0%) |
| drawer | 300 | 1x | 0.76 (0.83) | 19.4 (19.7) | 0.71 (0.73) | 0.9 | 16.7 / 16.8 | 0% (0%) |
| drawer | 500 | 1x | 0.84 (0.80) | 36.1 (35.3) | 0.63 (0.68) | 1.3 | 16.7 / 16.7 | 0.2% (0%) |
| drawer | 0 | 4x | 2.07 (1.97) | 1.2 (1.2) | 0.58 (0.58) | 3.3 | 16.7 / 16.7 | 0% (3.5%) |
| drawer | 100 | 4x | 2.09 (2.12) | 7.7 (7.8) | 0.59 (0.58) | 3.4 | 16.7 / 16.8 | 0.2% (1.7%) |
| drawer | 300 | 4x | 2.42 (2.40) | 21.7 (21.6) | 0.63 (0.59) | 3.8 | 16.7 / 16.7 | 0.2% (3.6%) |
| drawer | 500 | 4x | 5.54 (5.99) | 39.0 (39.0) | 0.70 (0.70) | 15.3 | 16.7 / 16.8 | 2.9% (1.7%) |
| demo | 0 | 1x | 0.55 (0.55) | 1.7 (1.7) | 0.41 (0.49) | 0.8 | 16.7 / 16.8 | 0% (0%) |
| demo | 100 | 1x | 0.57 (0.60) | 7.4 (7.7) | 0.48 (0.52) | 0.8 | 16.7 / 16.8 | 0% (0%) |
| demo | 300 | 1x | 0.75 (0.70) | 20.9 (20.2) | 0.44 (0.41) | 1 | 16.7 / 16.7 | 0% (0%) |
| demo | 500 | 1x | 6.78 (6.68) | 34.5 (34.3) | 0.55 (0.49) | 18.2 | 16.7 / 33.3 | 10.3% (0%) |
| demo | 0 | 4x | 1.77 (1.73) | 1.8 (1.8) | 0.47 (0.43) | 3 | 16.7 / 16.7 | 0% (0%) |
| demo | 100 | 4x | 1.85 (1.85) | 8.2 (8.2) | 0.41 (0.42) | 3.1 | 16.7 / 16.7 | 0% (0%) |
| demo | 300 | 4x | 2.26 (2.30) | 22.6 (22.4) | 0.45 (0.47) | 3.7 | 16.7 / 16.7 | 0% (0%) |
| demo | 500 | 4x | 8.45 (8.91) | 36.6 (36.7) | 0.49 (0.48) | 20.2 | 16.7 / 33.3 | 14.3% (0%) |



### Viewer apply / undo, drawer undo (ms)

| strokes | rate | viewer apply: to DOM | viewer apply: painted | long tasks (max) | viewer undo: painted | drawer undo: painted | idle viewer busy ms/s |
|---|---|---|---|---|---|---|---|
| 0 | 1x | 4.6 / 5.3 (4.4) | 4.9 / 5.7 (4.7) | 0 (0) | 4.6 / 6.6 (4.7) | 7.7 / 9.8 (7.3) | 5.2 (5.2) |
| 100 | 1x | 5.7 / 8 (5.6) | 6.2 / 9 (5.9) | 0 (0) | 5.6 / 7.4 (5.5) | 7.5 / 9.3 (7.6) | 7.0 (6.9) |
| 300 | 1x | 7.5 / 9.4 (8.2) | 7.8 / 9.8 (8.7) | 0 (0) | 7 / 7.7 (7.7) | 7.3 / 9.2 (7.9) | 8.6 (8.7) |
| 500 | 1x | 10.5 / 13 (10.7) | 11.1 / 16.7 (11.3) | 0 (0) | 9.4 / 10.7 (9.9) | 8.5 / 9.7 (8) | 9.6 (10.1) |
| 0 | 4x | 15.6 / 20.6 (16.5) | 17 / 23.1 (17.7) | 0 (0) | 18.1 / 21.3 (17.5) | 38 / 49.4 (43) | 21.4 (19.9) |
| 100 | 4x | 20.9 / 26 (22.1) | 22 / 28.1 (23.4) | 0 (0) | 21.8 / 28.4 (22) | 42.3 / 49.2 (39.7) | 22.3 (26.7) |
| 300 | 4x | 30 / 35.4 (31.7) | 32.3 / 38 (33.5) | 0 (0) | 28 / 46.3 (30.1) | 36 / 45.9 (36.4) | 31.5 (55.7) |
| 500 | 4x | 40.8 / 46 (41.3) | 43.1 / 75.9 (43.6) | 0 (0) | 39.1 / 44.7 (38.6) | 34.8 / 49.5 (40.7) | 37.0 (41.6) |


### Loads (ms)

| strokes | rate | viewer: painted | viewer: data to paint | viewer: long tasks / busy until | demo: painted | demo snapshot: handled / painted | drawer: painted | viewer HTML (gzip) | demo snapshot |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 1x | 35 / 86 (38) | 26 / 77 (28) | 0 / 0 | - / - (-) | - (-) / - / - (-) | 34 | 34861 (8908) | 48 |
| 100 | 1x | 48 / 118 (49) | 32 / 101 (33) | 0 / 0 | 97 / 112 (97) | 0.8 (0.9) / 2.1 / 2.3 (2.3) | 140 | 298127 (59213) | 121054 |
| 300 | 1x | 73 / 104 (73) | 40 / 70 (41) | 53 / 162 | 110 / 112 (110) | 2.4 (2.7) / 4.8 / 5.1 (5) | 183 | 834015 (157562) | 382317 |
| 500 | 1x | 106 / 116 (107) | 52 / 55 (52) | 60 / 221 | 108 / 115 (107) | 3.7 (3.9) / 6.9 / 7.4 (7) | 166 | 1452167 (275222) | 648288 |
| 0 | 4x | 131 / 155 (131) | 122 / 127 (121) | 175 / 336 | - / - (-) | - (-) / - / - (-) | 160 | 34861 (8904) | 48 |
| 100 | 4x | 164 / 172 (174) | 150 / 157 (158) | 217 / 394 | 341 / 358 (365) | 4 (3.4) / 9.1 / 11 (8.7) | 575 | 298127 (59226) | 121054 |
| 300 | 4x | 229 / 247 (229) | 193 / 215 (188) | 317 / 764 | 364 / 392 (388) | 9.8 (9.6) / 18.3 / 18.9 (19.3) | 732 | 834015 (157550) | 382317 |
| 500 | 4x | 308 / 321 (310) | 251 / 270 (252) | 444 / 1111 | 414 / 420 (415) | 16.6 (16.1) / 30 / 31.1 (30.6) | 886 | 1455099 (275238) | 648288 |

### Memory (1x, page loaded in a new browser context, after GC)

| strokes | viewer heap / live nodes / document nodes | drawer | demo |
|---|---|---|---|
| 0 | 4.8 MB (4.8) / 1373 / 722 | 4.9 MB (4.9) / 1471 / 780 | 4.0 MB (4.0) / 1307 / 702 |
| 100 | 5.1 MB (5.1) / 2273 / 922 | 5.0 MB (5.4) / 1571 / 880 | 4.1 MB (4.1) / 1407 / 802 |
| 300 | 5.7 MB (5.7) / 4073 / 1322 | 5.3 MB (5.3) / 1771 / 1080 | 4.4 MB (4.4) / 1607 / 1002 |
| 500 | 6.2 MB (6.2) / 5873 / 1722 | 5.5 MB (5.5) / 1971 / 1280 | 4.6 MB (4.6) / 1807 / 1202 |



With the layout's glow shown (drawer, 1x): compositor 35.4 ms per frame at 0 strokes and 35.7 at 500 (vs ~0.8 hidden); frame interval median 33.3 / 33.3 ms, 98.5% / 97.0% of frames over 16.7 ms.

Hologram logs per viewer apply: 14, 114, 314, 513 at 0/100/300/500 strokes. With the logs reaching the debugger (1x, 300 strokes): apply to DOM 101.3 ms (109.7).

### Leak check (1x; room 100 strokes and demo board 500 strokes, cleared and refilled)

The three pages stay open through the cycles, so their heap includes what
earlier documents left in the tab's isolate (the absolute levels differ
between runs); the growth is the figure.

| page | JS heap after 1 cycle | after 11 | after 21 | live DOM nodes (start = end) |
|---|---|---|---|---|
| viewer | 21.5 MB (15.1) | 26.2 MB (19.1) | 29.0 MB (22.6) | 6117 = 6117 |
| drawer | 26.2 MB (9.5) | 30.2 MB (13.6) | 33.7 MB (17.1) | 3341 = 3341 |
| demo | 20.7 MB (16.4) | 20.8 MB (16.5) | 20.8 MB (16.4) | 12542 = 12542 |


Bundles (prod release built from this tree; guard `max_bundle_size: 840_000`,
`config/config.exs:107`):

| bundle | bytes | share of guard | gzip |
|---|---|---|---|
| runtime | 588,079 | 70.0% | 137,267 |
| GamePage | 626,937 | 74.6% | 64,042 |
| HomePage | 429,980 | 51.2% | 41,747 |
| GameScorePage | 301,055 | 35.8% | 32,053 |
| ProfilePage | 269,623 | 32.1% | 25,823 |
| PastGamesPage | 234,515 | 27.9% | 22,637 |
| RoomLinkPage | 218,197 | 26.0% | 21,164 |

The dev server's last build has runtime 671,104 (79.9%) and GamePage 571,106.
The drawing features have ~210 KB of headroom on GamePage in prod and
~170 KB on the dev runtime.

Run agreement (client): 163 of 165 compared medians agree within 15%
(`node bench/compare.mjs bench/results/client-run1.json
bench/results/client-run2.json`; 34 more are under the 1 ms floor and listed
only). The two outside are borderline: the demo board's snapshot handling at
4x with 100 strokes (4.0 -> 3.4 ms, -15.0%) and the drawer's undo at 4x with
500 strokes (34.8 -> 40.7 ms, +17.0%, one Hologram action and render). Each
earlier pair of runs also left one or two medians at 15-18%, different ones
each time, so this is the noise of headless timing on this machine rather
than a drift; the figures the findings and budgets rest on (raster and main
thread per frame, viewer apply and undo, loads, memory) agree within 12%.

### How the client numbers were made trustworthy

- Production build, not the dev server; Hologram's own `console.log`s
  (every render, action and, during an action, every compiled function call:
  prod too) are dropped in the page, as they never reach a debugger for a
  visitor without DevTools. Kept, they make a viewer's apply at 300 strokes
  ~10x slower (finding 7).
- One browser process per page: three pages in one headless browser halve
  each page's frame rate.
- The layout's `.footer-glow` (an animated `blur(90px)` layer, visible below
  the short game page at 1280x900) and `.nav-glow` are hidden: in software
  compositing the footer glow alone costs 35-42 ms of compositor time per frame
  and holds the game page at 20-30 fps whatever the canvas does (see "with
  the glow" above). They must be hidden after Hologram has mounted: its
  first patch undoes an earlier inline style.
- Memory is read in a new browser context (same sign-in, its own renderer
  process) with the back/forward cache off: pages loaded one after another in
  one tab can share a V8 isolate with what earlier documents left behind,
  which more than tripled some heap readings.
- Two unmeasured loads per page first (a fresh browser's first navigations
  are slower).
- Medians tied to the 60 Hz frame clock (frame intervals, wall-clock
  latencies that include the wait for the next frame), sums of long tasks,
  and the demo board's snapshot costs while its page boots are reported in
  `frame_aligned` / `thresholded` / `during_load` groups and not used for the
  agreement check: they move in 16.7 ms or 50 ms steps or with the boot.
  Each has a compared counterpart that measures the same cost (main thread
  and raster per frame from the trace, painted cost, data-to-paint, the
  snapshot on an idle page).

## Findings, ranked by cost

1. **Every frame of a gesture re-rasterizes all committed strokes.** On
   both canvases, raster time per frame grows linearly with the strokes held,
   ~0.075 ms per stroke: 1.2 / 7.4 / 19.4 / 36.1 ms at 0/100/300/500 (drawer, 1x;
   the demo board is the same). The main thread stays near 0.74 / 0.70 /
   0.76 / 0.84 ms a frame (drawer, 1x): the engine itself is cheap. At 500
   strokes the main thread's paint of that layer jumps as well (demo board
   6.8 ms a frame at 1x, drawer 5.5 ms at 4x). The stroke in progress
   (`#drawing-path`, `#demo-board-active-path`) is painted in the same layer
   as the committed paths, so each frame's damage (the active path's bounds,
   most of the canvas for a scribble) is re-rastered with every committed
   path under it. This
   machine still shows ~60 fps only because a fast desktop CPU spreads the
   raster over several worker threads; the demo board at 500 already drops
   10.3% of frames at 1x (none when idle). On a phone (fewer, slower
   cores, or GPU raster tessellating every path) ~37 ms of desktop raster per
   frame cannot fit a 16.7 ms frame: expect visible stutter well before 500
   strokes. Measured fix in the rendering decision below.
2. **A viewer re-renders the whole game page for every stroke, undo and
   countdown tick.** `:stroke_completed` is applied by Hologram re-rendering
   the page with the full stroke list (`game_page.ex` `add_viewer_stroke/3`,
   `DrawingCanvas`): 4.6 / 5.7 / 7.5 / 10.5 ms at 0/100/300/500 strokes (1x) and
   15.6 / 20.9 / 30 / 40.8 ms (4x). Undo costs the same.
   The idle page re-renders every path once a second (the countdown tick):
   5.2 / 7.0 / 8.6 / 9.6 ms/s (1x), 21.4 / 22.3 / 31.5 / 37.0 ms/s (4x). The floor (any Hologram
   action plus a page render, 0 strokes) is ~4.5 ms at 1x and ~20 ms at 4x;
   everything above it grows with the strokes.
3. **Game pages leak ~4 KB per Realtime action.** Over 20 load-and-clear
   cycles (100 strokes each, ~2,000 broadcasts) the viewer's and the drawer's
   JS heap grow ~7 MB and keep growing in the second half (viewer 21.5 ->
   26.2 -> 29.0 MB, drawer 26.2 -> 30.2 -> 33.7 MB; run 2: +4.0 and +3.5 MB
   for both); the
   demo board (Phoenix channel, no Hologram action per push) stays flat. A heap
   snapshot diff traces it to Hologram's runtime: `:binary.compile_pattern/1`
   registers each compiled pattern in `ERTS.binaryPatternRegistry` under a new
   ref and nothing ever removes it; each `:stroke_completed` on a game page
   leaves two (a 256-entry `badShift` table of ~1.4 KB plus the pattern
   bytes). The call site on the action's path isn't identified yet (GamePage
   itself has no `String.split`/`contains?`/`:binary.match`); a long game
   (24 rounds, chat, deltas) reaches ~10 MB.
4. **A joining viewer gets the canvas twice, and a phone stays busy for a
   second.** At 500 strokes the game page HTML is 1.45 MB (275 KB gzip; 35 KB
   with no strokes): the strokes are in the page state (717 KB) and in the
   rendered `<path>`s. Data to painted canvas is 52 / 251 ms (1x / 4x, within
   the 300 ms budget), but at 4x the main thread runs long tasks until
   1111 ms after navigation (336 ms with no strokes: the boot
   grows with the state it decodes and the page it mounts). The
   drawer's own reload (`restoreStrokes`) paints after 166 / 886 ms (1x / 4x).
   The demo board's snapshot is 648 KB at 500 fixture strokes and, with no
   byte cap, up to 4.03 MB (500 x 7,999 bytes); handling and painting it
   costs only 6.9 / 30 ms (1x / 4x).
5. **Detached DOM nodes on the viewer.** A freshly loaded viewer page holds
   far more live DOM nodes than its document (1373 vs 722 / 5873 vs 1722 at 0 / 500 strokes,
   live vs in the document): ~9 live nodes per stroke against 2 in the
   tree, so the server-rendered paths stay alive next to the ones Hologram
   mounted. The demo board and the drawer (JS-built canvases) don't
   (demo board 1807 vs 1202, drawer 1971 vs 1280 at 500). The JS heap barely moves (viewer 4.8 / 6.2 MB at 0 / 500
   strokes); the retained nodes are Blink memory.
6. **The footer glow is expensive to composite.** The animated
   `blur(90px)` `.footer-glow` shows below the short game page at desktop
   sizes and, in software compositing, costs 35-42 ms per frame, holding the
   page at 20-30 fps whether or not anyone draws. A GPU makes this much
   cheaper, so the size of this one depends on the device; it still re-blurs
   a large layer on every frame of its 9 s animation.
7. **Hologram's logging under a debugger.** During an action the runtime
   logs every compiled function call, one per held stroke on `:stroke_completed`
   (14 / 114 / 314 / 513 logs at 0/100/300/500). With DevTools open (or any CDP client)
   an apply at 300 strokes takes 101 ms instead of ~10. Only people
   with DevTools open pay it (QA, the owner), but it distorts any profiling.
8. **The server side is cheap.** A commit costs 11-27 us (O(n) parts add
   ~15 us at 499), undo 17 us, clear 6 us; a full room is ~0.85 MB (paths
   0.62 MB), a full demo board 0.76 MB; relaying 20 chunks/s to 200 visitors
   uses 0.7% of the schedulers with no mailbox over 5 and a 3.5 ms p95
   delivery. Per viewer, the SSE stream encodes each stroke separately (17 us
   for a medium path, 38 us for a long one): 50 watchers cost ~2 ms per
   stroke. Nothing here needs work; the demo board's missing byte cap
   (finding 4) is the one server-side item.

## Budgets

For `draw-optimize` (#44) to meet, and for #37-#43 not to break. "Today" is
the 1x / 4x median (p95 where stated) at the stroke count given.

| scenario | today | budget | vs. the starting point |
|---|---|---|---|
| drawing, both canvases, 500 strokes: frame interval p95 | drawer 16.7 / 16.8, demo 33.3 / 33.3 | <= 16.7 ms at 1x, <= 33 ms at 4x | confirmed |
| drawing: frames over 16.7 ms | demo 10.3% / 14.3% at 500 (idle 0%) | <= idle + 2 points | new |
| drawing: raster per frame, any stroke count | 36.1 / 34.5 ms (drawer / demo) at 500 (1.2 / 1.7 at 0) | <= 3 ms (no growth with strokes) | new: this desktop's parallel raster hides what a phone can't |
| drawing: main thread per frame (trace), 500 strokes | drawer / demo 0.84 / 6.78 ms at 1x, 5.54 / 8.45 at 4x | <= 1 ms at 1x, <= 3 ms at 4x (the 300-stroke level) | new |
| drawing: frame work p95 (rAF to rendered), 500 strokes | drawer 1.3 / 15.3, demo 18.2 / 20.2 | <= 8 ms at 1x, <= 16 ms at 4x | new |
| viewer: stroke applied (to the DOM) | 7.5 / 30 at 300; 10.5 / 40.8 at 500 | <= 6 ms at 1x and <= 24 ms at 4x at 500 strokes (the 0-stroke cost + 25%) | corrected: "8 ms at 300" is nearly met at 1x; the problem is the growth and 4x |
| viewer: undo applied | 9 / 36.5 at 500 | same as apply | new |
| viewer: idle page | 9.6 / 37.0 ms/s at 500 | no growth with strokes (<= 12 / 32 ms/s) | new |
| join: canvas painted after the data, 500 strokes | viewer 52 / 251 ms; demo 6.9 / 30 ms | <= 300 ms at 4x | confirmed (met today) |
| join: main thread busy until, viewer, 500 | 221 / 1111 ms | <= 600 ms at 4x | new |
| join: viewer page HTML, 500 fixture strokes | 1.45 MB (275 KB gzip) | <= 800 KB (strokes sent once), <= 160 KB gzip | new |
| demo snapshot, worst case | 648 KB (500 fixture strokes), 4.03 MB possible | <= 500 KB (a byte cap on the board) | confirmed |
| heap growth over 20 load-and-clear cycles | +7 MB, still growing (game pages); flat (demo) | second half <= 0.5 MB on every page | confirmed (0.5 MB allows for JIT warm-up) |
| live DOM nodes vs document nodes, 500 strokes | viewer 5,873 vs 1,722 (demo 1,807 vs 1,202) | <= document nodes + 1,000 | new |
| server: commit at 499 strokes | 27 us | <= 100 us | new (guard) |
| server: fan-out, 200 subscribers at 20 chunks/s | 0.7% schedulers, mailbox <= 5 | <= 5%, mailbox <= 10 | new (guard) |
| bundles | GamePage 626,937 B prod | <= 840,000 (the guard) | unchanged |

## Rendering decision

**Committed strokes can stay SVG `<path>`s up to 500 strokes, on condition
that the stroke in progress is drawn in its own compositor layer, above a
layer that holds only committed strokes. A bitmap layer is not needed.
Separately, viewer strokes must leave the Hologram template.**

Evidence:

- Raster per frame is what grows with the strokes held, linearly and the
  same on both canvases (finding 1); main-thread time per frame stays flat
  up to 300 strokes and jumps only at 500 (painting that same layer). So the
  cost is the shared paint layer, not the number of SVG nodes or the DOM
  work.
- The experiment (`bench/own_layer.mjs`, demo board, same gesture): moving
  the committed strokes into a second svg under the canvas with its own
  layer (`will-change: transform`) takes raster per frame at 500 strokes from
  32.5 ms to 0.6 ms (below the 0-stroke level), and the
  page's frame work (rAF to rendered, mean) from 6.3 to
  0.5 ms. A
  commit then costs one raster of the new stroke's area (6.7 ms,
  once per stroke, not per frame).
- A bitmap (canvas) layer would also fix the per-frame raster, but undo by
  id becomes a redraw of every remaining stroke, resizing needs a redraw at
  the new pixel size, and the per-stroke nodes the overlay handoff and the
  tests use (`data-stroke-id`) go away. The layer split keeps all of that and
  measures as good.
- Viewer apply grows with the strokes because Hologram re-renders the page
  (finding 2), not because of SVG. Rendering the viewer's strokes from JS into
  a JS-owned group, as the drawer's and the demo board's already are (one
  node per stroke, `removeChild` per undo), makes apply O(1), takes the paths
  out of every countdown re-render, and removes the second copy of the
  strokes from the HTML (finding 4).

So `draw-optimize` implements: (1) a separate, composited layer for the
stroke in progress and the live overlays on both canvases; (2) viewer
strokes out of the template, JS-owned, applied per push. Re-measure with
`bench/drawing_client.mjs` against the budgets above; only if raster per
frame still grows with strokes after (1) should a bitmap layer be considered.
