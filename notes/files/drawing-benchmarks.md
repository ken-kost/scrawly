# Drawing benchmarks: baseline, budgets, the rendering decision, and #44's results

How to run and how each number is taken: `bench/README.md`.

- Task #44 (`draw-optimize`), this first part: the benchmark extended with
  the features' work, re-run on the same machine after #37-#43 ("after
  features", `bench/results/{client,server}-after-features.json`), the
  changes made in order of cost, each measured before and after, and the
  final run (`bench/results/{client,server}-final.json`).
- Task #36 (`draw-bench`), from "#36: baseline" down: the baseline taken
  before the drawing features, the budgets, the findings and the rendering
  decision. Raw results: `bench/results/{server,client}-run{1,2}.json`.

## #44: after the features, and after the optimisations

Same machine and toolchain as #36 (Core i9-11950H, WSL2, software
compositing, Erlang 28.3.3 / Elixir 1.19.7, Hologram 0.12.8, Chromium
Playwright build 1181), 2026-11-16, branch `drawing-tools` at 61eb7a3 plus
#44's working tree. Every client figure is from a prod release built from
the tree being measured (`bench/prod_server.sh`). The board's rows of #36's
baseline were taken on its 400x225 board (#37 changed it), so for the board
"after features" is the baseline.

### New scenarios (bench/README.md has the details)

- **Tools** (the drawer's canvas, every size, 1x and 4x): the size ring
  following the mouse (`drawer_hover`), eyedropper picks (`drawer_pick`),
  fills at the corner (the white around the drawing, the biggest area) and
  at the centre, each undone (`drawer_fill`: pointerdown to the frame
  showing the shape; main thread and fill worker from a trace), a one-second
  drag on the size slider and on the colour wheel (real CDP mouse input).
- **Fixtures with fills** (`bench/fixtures/{game,demo}-fills-*.json`, made
  by the fill tool's own worker in Chromium): every tenth stroke a fill, 50
  at 500 strokes, 734 KB of path data; the drawer, board and viewer
  scenarios at 500 with them (`runs_fills`), and the server's join payloads
  with them.
- **Board undo with 200 connected sockets** (server benchmark, also 10 and
  50): the owner undoes 40 strokes 50 ms apart; the call, scheduler use and
  each visitor's receipt of `stroke_removed`.
- **Memory after 20 rounds that use every tool** (`leak_tools`): the drawer
  and a board visitor each draw three strokes, a Ctrl and a right-button
  stroke, pick with Alt, step the size keys, pick on the wheel, fill,
  Ctrl+Z, clear; the viewer follows. Heap and nodes after 1, 11 and 21
  rounds.
- The server's memory per connected visitor, wire bytes, the board
  snapshot on the wire, and what the board's ownership data (#42) costs.

### What the features cost (after features, against #36's baseline)

- Drawing: the same raster growth (33.7 ms per frame at 500 strokes on the
  drawer, 29.5 on the board); the drawer's main thread per frame +0.2-0.3 ms
  at 1x and +1-1.5 ms at 4x (the size ring and the pointer followers of the
  eyedropper and the fill cursor run every frame).
- The drawer's undo: painted 8.5 -> 13.9 ms (1x, 500) and 34.8 -> 50.7 (4x):
  Ctrl+Z had become a page action dispatched through
  `Hologram.dispatchAction` (a timer hop and an action before the stroke
  leaves the canvas).
- The viewer: apply +4-13% (a bigger page to re-render), idle +23% (1x).
- The board's load: painted 108 -> 275 ms (1x) and 414 -> 644 (4x): since
  #42 the board connects after a command round trip (`:board_token`).
- The leak got no worse per action (~3.5 MB per 1,000 strokes on game
  pages); rounds with the new tools leaked 2.3 MB per 10 rounds on the
  drawer.
- Bundles: GamePage 626,937 -> 698,767 B (prod), 808,979 in the test env
  against the 840,000 guard.
- Join payloads with fills: viewer HTML 1.67 MB at 500 strokes with 50
  fills (317 KB gzip), the board snapshot 765 KB.

### What #44 changed, in order of cost, and what each bought

Measured with targeted runs of the client benchmark against the previous
step's release (`--only`, `--sizes`), then all together in the final run.
Every step passed `mix test` and the JS tests.

| # | change | what it bought (medians, 500 strokes unless said) | kept |
|---|---|---|---|
| 1 | **Committed strokes and the stroke in progress in two svgs**, stacked, same viewBox: `#…-paint` (committed strokes, no pointer events) under `#…-svg` (the stroke in progress and live overlays; the svg the engine listens to; its own compositor layer, `will-change: transform`), on the game canvas and the board (the rendering decision) | raster per frame 33.7 -> 1.28 ms (drawer, 1x), 38.2 -> 0.94 (4x); board 29.5 -> 0.82 / 31.9 -> 0.83; main thread per frame at 4x 6.78 -> 4.15 (drawer), 7.78 -> 3.9 (board); frame work p95 at 4x 15.2 -> 5.1, 18.3 -> 5.0. The cursor attributes (`data-size-ring`, `data-pick`, `data-fill`) now restyle the input svg's few children instead of every committed path | yes |
| 2 | **Viewer strokes JS-owned**, like the drawer's: one node per stroke in `#game-canvas-strokes`, drawing_manager.mjs keeps the list with each broadcast's seq (GamePage keeps the gap rule and hands over every stroke, undo, clear and snapshot with its seq); the canvas at load is one JSON string in the page state, drawn on `:mounted` (drawer and viewer); Hologram renders no stroke | viewer apply 10.9 -> 4.0 ms (1x), 46.3 -> 15.4 (4x), flat with the strokes (4.0 at 0); viewer undo 10.6 -> 4.4 / 43.6 -> 16.7; idle viewer flat with the strokes; viewer HTML 1.45 MB -> 693 KB; busy until (4x) 1137 -> 642 ms; live DOM nodes 5,397 -> 1,906 (document 1,236); Hologram logs per apply 515 -> 20, and with DevTools open an apply at 300 strokes 104 -> 5 ms; the drawer's load 917 -> 822 ms (4x). **Cost: a viewer's canvas now paints after Hologram has booted** (see "Budgets still missed") | yes |
| 3 | **Hologram leak worked around**: the word display's blocks and label (`PlayFeedback.word_view/1`) worked out when the word changes and kept in the page state, never in the template (the template called `String.split/2` twice per render; upstream issue 1 below) | load-and-clear cycles, second half: viewer +3,490 KB -> +52 KB, drawer +3,557 -> -112 KB | yes |
| 4 | **Size ring hidden while a stroke is drawn** (the canvas keeps its crosshair) | drawer main thread per frame 1.2 -> 1.11 ms (1x), 4.15 -> 3.81 (4x); 3.61 -> 2.78 at 0 strokes (4x) | yes |
| 5 | **Ctrl/Cmd+Z undoes natively** on the canvas in the document (`registerCanvasUndo`), no Hologram action first; the undo button keeps the page action | drawer undo to DOM 12.6 -> 0.4 ms (1x), 26 -> 1.4 (4x); painted 17.4 -> 6.2 / 49.7 -> 27.8 | yes |
| 6 | **The glows without a blur filter** from 721 px up: the same soft radial gradient in a box larger by the blur's spread (app.css); phones keep `blur()` | with the glow shown (1x): compositor 44.1 / 34.4 -> 2.9 / 3.3 ms per frame (0 / 500 strokes), frames over 16.7 ms 94% -> 0%, frame interval 33 -> 16.7 ms. The look: within 8/255 per channel of the blurred glow at 1440 px, 16 at 1024, 21 at 800, both themes (shots below) | yes |
| 7 | **The board's byte cap**: at most 450,000 path bytes as well as 500 strokes (the oldest go first), the count and bytes kept in its state, the same limits in demo_board.mjs's store | snapshot at the 500 fixture strokes 648 KB -> 470 KB (it keeps 360), worst case 4.03 MB -> 451 KB, with fills 765 -> 467 KB; board commit at 499 14.0 -> 11.2 µs | yes |

Tried and dropped:

- **Pausing the glows' animation during a stroke** (Web Animations
  `pause()` from the stroke engine): compositor time with the glow shown
  stayed at 33-37 ms per frame (the blurred layer is redrawn whether it
  moves or not). Replaced by change 6.
- **WebSocket compression on `/socket`** (`websocket: [compress: true]`,
  the visitors offering permessage-deflate as browsers do;
  `bench/results/server-compress-{off,on}.json`): bytes on the wire -64%
  for the snapshot (470 -> 171 KB) and -83% for live chunks, but server
  memory per connected visitor 12-40 KB -> 220-310 KB (each socket's zlib
  streams; the 32 KB window can't be shrunk from the server since browsers
  don't offer it), relay CPU per delivered chunk 21 -> 48 µs (scheduler use
  at 200 visitors 0.66% -> 1.3%), and ~30 ms of server time per snapshot
  sent (join to receipt 26 -> 56 ms). The memory decides it: 200 board
  visitors would hold ~60 MB of zlib state. The snapshot is capped by
  change 7 instead.
- **The room's stroke count and path bytes kept in its state**: the limit
  check at 499 strokes goes from 10.8 to 5.7 µs (`room_check_with_totals`),
  5 µs of a 25-28 µs commit that is far inside its 100 µs budget; four list
  resets in GameFlow/RoomServer and the tests' hand-built room states would
  all have to keep the totals in step. Not worth that risk.
- **Avoiding `list ++ [stroke]`** in RoomServer and DemoBoardServer: 0.64 µs
  at 499 strokes (2.5% of a commit); a reversed list would have to be
  reversed by every reader (views, replays, the score page, the tests).
- **The committed strokes' svg on a layer of its own too** (`will-change`
  on `.canvas-paint`, in-page A/B): no measurable difference (0.84-1.0 ms
  per frame either way at 500, 1x).
- **Server-rendered viewer paths for the first paint**, next to the JSON
  canvas: Hologram has no server-only state, so the paths would go twice in
  the HTML again (1.45 MB), and its boot patch removes markup it didn't
  render. Not done; see the join budget below.

### Final results against the budgets

Medians at 1x / 4x: #36 baseline, after features (#37-#43), final (#44).

| budget (from #36) | #36 baseline | after features | final | met |
|---|---|---|---|---|
| drawing at 500, frame interval p95 <= 16.7 ms (1x) / 33 (4x) | drawer 16.7 / 16.8, board 33.3 / 33.3 | drawer 16.7 / 16.8, board 16.7 / 16.8 | drawer 16.7 / 16.8, board 16.7 / 16.7 | yes |
| frames over 16.7 ms <= idle + 2 points (500) | board 10.3% / 14.3% (idle 0) | board 0.9% / 4.2% (idle 0) | drawer 0 / 0.7%, board 0 / 0.2% (idle 0) | yes |
| raster per frame <= 3 ms, no growth with strokes | drawer 36.1 / 39.0 at 500 (1.2 at 0) | 33.7 / 38.2 | 1.26 / 0.89 (0.53 / 0.57 at 0); board 0.81 / 0.73; with 50 fills 1.29 / 0.93 | yes |
| main thread per frame at 500 <= 1 ms (1x) / 3 (4x) | drawer 0.84 / 5.54, board 6.78 / 8.45 | 1.03 / 6.78, 1.09 / 7.78 | drawer 0.95 / 3.8, board 0.98 / 3.2 | 1x yes; **4x no** |
| frame work p95 at 500 <= 8 ms (1x) / 16 (4x) | drawer 1.3 / 15.3, board 18.2 / 20.2 | 1.6 / 15.2, 11.3 / 18.3 | 1.2 / 4.4, 1.2 / 4.2 | yes |
| viewer stroke applied (to DOM) at 500 <= 6 ms / 24 | 10.5 / 40.8 | 10.9 / 46.3 | 4.5 / 15.3 (4.4 / 15.6 at 0 strokes) | yes |
| viewer undo applied, the same | painted 9.4 / 39.1 | 10.6 / 43.6 | 5.1 / 16.6 | yes |
| idle viewer, no growth with strokes (<= 12 / 32 ms/s) | 9.6 / 37.0 at 500 | 11.9 / 41.7 | 5.5 / 22-31 at 500, 5 / 20-32 at 0 (three 5 s windows; the bench's single 2 s window read 11.0 / 46.3) | yes |
| join: canvas painted after the data, 500, <= 300 ms (4x) | viewer 52 / 251, board 6.9 / 30 | 52 / 244, board 10 / 51 | viewer **167 / 630**, board snapshot 8 / 36 | **viewer no**, board yes |
| join: main thread busy until, viewer 500, <= 600 ms (4x) | 221 / 1111 | 239 / 1137 | 0 / 412 | yes |
| viewer page HTML at 500 <= 800 KB, <= 160 KB gzip | 1.45 MB (275 KB) | 1.45 MB (275 KB) | 695 KB (262 KB); with 50 fills 808 KB (302 KB) | size yes (fills +1%); **gzip no** |
| board snapshot, worst case <= 500 KB | 648 KB, 4.03 MB possible | 648 KB, 4.03 MB | 470 KB at the fixtures, 451 KB worst, 467 KB with fills | yes |
| heap growth, second half of 20 cycles <= 0.5 MB | viewer +2.9 MB, drawer +3.5, board flat | +3.5, +3.6, -0.1 | +0.05, +0.05, -0.14 | yes |
| the same over 20 rounds with every tool (new) | - | viewer +0.73 MB, drawer +2.3, board +0.25 | viewer +0.22, drawer **+0.90**, board +0.19 | **drawer no** (JIT code, below) |
| live DOM nodes <= document nodes + 1,000 (500) | viewer 5,873 vs 1,722 | 5,397 vs 1,234 | viewer 1,906 vs 1,236; board 1,909 vs 1,125; drawer 2,216 vs 1,332 | yes |
| server: commit at 499 strokes <= 100 µs | 27.1 | 25.6 | 24.9 (board 11.2) | yes |
| server: fan-out, 200 visitors at 20 chunks/s: <= 5% schedulers, mailbox <= 10 | 0.7%, 5 | 0.63%, 1 | 0.66%, 1; board undo with 200 connected 0.88%, every push delivered, p95 3.1 ms | yes |
| bundles <= 840,000 B | GamePage 626,937 (prod) | 698,767 prod / 808,979 test env | 696,885 prod / **806,659** test env (-2,320) | yes |

Other bundles (test env, after features -> final): HomePage 582,910 ->
585,818 (+2,908) and GameScorePage 367,490 -> 369,684 (+2,194), both from
their copies of drawing_manager.mjs and draw_controls.mjs (Hologram 0.12
copies a JS module into every bundle that can reach it). Prod: HomePage
519,159 -> 522,067, GameScorePage 336,602 -> 338,788; runtime unchanged.

Scenarios slower than their baseline by more than 15% (`node bench/compare.mjs`):

- **A viewer's join paint** (every size above 0; at 500 strokes 52 -> 167 ms
  at 1x and 244 -> 630 ms at 4x): the trade of change 2, below.
- **The drawer's undo, painted** (8.5 -> 20 ms at 1x, 500, in the final run;
  6.1 in a re-run): the undo itself is now 0.4 ms (3.3 at #36); "painted"
  adds the next frame's main-thread work, which now often includes the op
  queue's `send_stroke_op` action and its page render, queued right after
  the key. The undo is on screen in the first frame either way.
- **The drawer's main thread per frame at 4x with few strokes** (2.07 ->
  2.88 ms at 0, 2.42 -> 3.5 at 300; at 500 5.54 -> 3.8, better): the
  features' per-frame pointer work (the ring, the pick swatch and the fill
  cursor followers, #38-#43) plus the input svg's extra layer; hovering
  with the ring at 4x and 0-100 strokes is +0.7 ms per frame against after
  features (1.4 -> 2.1-2.4), the same at 300-500 strokes.
- The board's load (a #42 cost against #36), its compositor time per frame
  (0.7 -> 1.2 ms: two composited layers instead of one, on the compositor
  thread) and a few tool figures with four samples each (fills, picks)
  whose medians move within their own spread.

### Budgets still missed, and why

- **A viewer's canvas paints after Hologram boots** (data to paint at 500:
  167 ms at 1x, 630 at 4x; budget 300 at 4x). With the strokes out of the
  template (the rendering decision), nothing paints them until the page's
  JavaScript has loaded, mounted and run `:mounted` (at 4x ~300 ms of
  Hologram boot at 0 strokes, then decoding the state and drawing the
  canvas). Before, the server-rendered paths showed at first paint, at the
  price of the strokes twice in the HTML, 5,400 live nodes and 40-48 ms per
  stroke at 4x. The drawer's canvas has always worked this way (822 ms at
  4x, 917 before). Options for the owner: accept it (every other viewer
  figure is 2-3x better), or a pre-boot paint of the JSON canvas by an
  inline script, which would have to read Hologram's serialized page state
  (an internal format), so it isn't done here.
- **The page HTML's gzip size** (262 KB at 500; budget 160): the strokes
  now go once, but path text gzips only ~2.6x and gzip had already
  deduplicated the second copy; 160 KB would need a compact path encoding.
- **Main thread per frame at 4x, 500 strokes** (drawer 3.8 ms, board 3.2;
  budget 3): it no longer grows with the strokes (3.5 at 300, 2.9 at 0); it
  is the stroke in progress itself (a 7,000-character `d` re-parsed and
  painted per frame), the pointer followers and the frame's lifecycle at
  4x CPU.
- **The drawer's heap over 20 rounds with every tool** (+0.90 MB in the
  second half; budget 0.5): a heap snapshot diff shows V8 code (optimised
  code, feedback vectors) for the many Hologram functions the tools reach,
  levelling off: rounds 4-18 +1.07 MB, rounds 19-33 +0.38 MB, 94% `code:`
  objects plus PerformanceResourceTiming entries (bounded by the browser),
  no application objects. The load-and-clear leak is gone (+47 KB).

Measured but not budgeted (final, 1x / 4x, 500 strokes):

- Eyedropper pick: handler 0.4 / 1.7 ms (p95 5.2 / 10.3: the first pick
  after a page render forces a style update), on screen 1.2 / 5.5 ms.
- Fill at the corner: 33.7 / 87 ms from the click to the shape on screen,
  main thread 18.6 / 69 ms, the worker 14-15 ms; at the centre 19.4 / 51 ms.
  The main-thread part is mostly the commit's op-queue action and page
  render (#43's finding), unchanged.
- Size slider drag: 1.18 / 3.9 ms main thread per frame, no frame over
  16.7 ms, 10 `select_size` actions per second. Colour wheel drag: 1.5 /
  5.3 ms, 1.4% of frames over 16.7 ms at 4x, 12 `color_picked` per second.
- The ring following the mouse with no stroke: 0.65 / 2.1 ms main thread
  per frame, no raster.
- The drawer's page holding 500 strokes: 8.4 MB of JS heap (5.8 after the
  features; 5.8 at 300 strokes): a heap snapshot holds the canvas JSON
  string of the page's state (650 KB) after `:mounted` and two large
  external strings (the page's scripts); once per page load, not growing.
  The viewer's page: 6.1 MB (6.3 before).

### Server (final; `bench/results/server-final.json`)

- Commits at 0/100/300/499 strokes: room 10.9 / 12.9 / 18.2 / 24.9 µs,
  board 4.1 / 5.8 / 9.5 / 11.2 µs (at 499 fixture strokes the board holds
  360); room undo 15.8 µs, clear 5.3 µs.
- Memory holding the 500 fixture strokes: room 851 KB (the same as #36 and
  after the features), board 588 KB holding 360 (after the features 846 KB
  holding 500). **The board's ownership data** (each stroke's owner and
  gesture, #42): 34.6 KB of the board state's 118 KB heap at 360 strokes,
  ~96 B per stroke (the paths, 446 KB of binaries, are shared). With 50
  fills: room 965 KB, board 962 KB.
- Join payloads at 500: room view 53 µs (654 KB term); its strokes as
  Hologram state 717 KB (833 KB with fills), now sent as one JSON string
  (~650 KB); board snapshot 470 KB, built in 1.3 ms.
- Fan-out to 10 / 50 / 200 visitors: 0.14 / 0.22 / 0.66% of the schedulers,
  every chunk delivered, p95 1.7 / 2.0 / 3.2 ms, ~20-35 KB of server memory
  per visitor. Board undo with them connected: the call 0.2 / 0.37 / 0.70
  ms (the broadcast to every channel process is inside it), delivery p95
  1.1 / 1.6 / 3.1 ms, every push delivered.

### Hologram 0.12.8: the leak and the logging, for upstream

Neither is patched in `deps/`. Ready to send to Bart:

**1. Every raw-pattern `:binary.split/3`, `match/3`, `matches/3` and
`replace/4` call registers a compiled pattern that is never freed.**
`assets/js/erlang/binary.mjs`: `split/3` (~line 1284), `match/3` (~500),
`matches/3` (~625) and `replace/4` (~742) compile an uncompiled pattern
with `compile_pattern/1` (~238), which builds the Boyer-Moore table (a
256-key `badShift` object plus the bytes) or the Aho-Corasick trie and
stores it in `ERTS.binaryPatternRegistry`
(`assets/js/erts/binary_pattern_registry.mjs`) under a fresh `make_ref()`;
nothing deletes entries (`clear()` is only called by tests). So every
`String.split/2` in client code (Elixir's implementation calls
`:binary.split(string, pattern, [:global])`) leaks ~2 KB, and in a
template it does so on every render. Scrawly's game page called it twice
per render: ~3.5 MB per 1,000 strokes on a viewer's page, growing for as
long as the page stayed open. Minimal reproduction:

```elixir
defmodule Repro.SplitLeakPage do
  use Hologram.Page

  route "/split-leak"
  layout Repro.Layout

  def init(_params, component, _server), do: put_state(component, :n, 0)

  def template do
    ~HOLO"""
    <button $click="tick">renders: {@n}</button>
    {%for w <- String.split("a b c", " ")}<span>{w}</span>{/for}
    """
  end

  def action(:tick, _params, component), do: put_state(component, :n, component.state.n + 1)
end
```

Open `/split-leak`, run
`for (let i = 0; i < 2000; i++) Hologram.dispatchAction("tick", "page", {})`
in the console a few times and compare heap snapshots: the `Map` behind
`BinaryPatternRegistry.patterns` gains one entry per render (~4 MB per
2,000) and never shrinks. Suggested fix: register only the patterns user
code compiles itself with `:binary.compile_pattern/1`; for a raw pattern
build the table locally and let it be collected (or cache it in a small
bounded map keyed by the pattern bytes); a `FinalizationRegistry` on the
ref could free user-compiled ones too. Scrawly's workaround:
`PlayFeedback.word_view/1`, worked out when the word changes and kept in
the page state.

**2. Action profiling logs every compiled function call, in production
too, with no switch.** `Hologram.executeAction` (`assets/js/hologram.mjs`
~272) sets `globalThis.Hologram.isProfilingEnabled = true` for every
action; the interpreter's dispatch (`assets/js/interpreter.mjs` ~1862,
~1892) then `console.log`s `Hologram: function <mfa> executed in <ms>` for
every compiled function call until the action ends (~2406); actions and
renders are logged as well. `config :hologram` has no key for it (only
`client_stacktraces`, `client_error_overlay`, `max_bundle_size`), so there
is nothing to set for prod. Without DevTools a log is cheap but not free
(the message is built for every call); with DevTools open or any CDP
client attached each one is serialized: before #44 a viewer's stroke at
300 strokes took ~104 ms instead of ~9 (316 logs per action). Change 2 cut
that action to 20 logs (5 ms with DevTools open), but any action that
walks a long list pays it. Suggested fix: a config key, off by default in
`:prod` (e.g. `config :hologram, :client_profiling, false`, read into
`globalThis.Hologram.config` like `stacktraces`).

### Screenshots

`/tmp/holo_research/scratch/t44/shots/`: the glow before and after at
1440x900 on the game page (`glow-{before,after}-1440x900-game.png`, the
animation held at the same phase), at 1024x768 and at 1440x900 dark on the
home page (`glow-{before,after}-1024x768-home.png`,
`glow-{before,after}-1440x900-home-dark.png`), the phone, unchanged
(`glow-390x844-home-phone-unchanged.png`); the regression pass's canvases
(`{1440x900@1,390x844@2}-{game-drawer,game-viewer,game-viewer-rejoined,board,board-other-visitor}.png`).

### #36's findings, where they stand

1. Raster per frame with the strokes held: **fixed** (change 1).
2. A viewer re-rendering the page per stroke, undo and tick: **fixed**
   (change 2); a tick or a stroke still re-renders the page, but no stroke.
3. Game pages leaking ~4 KB per action: **worked around** (change 3); the
   cause is reported upstream.
4. The canvas twice in the viewer's HTML, no byte cap on the board:
   **fixed** (changes 2 and 7); the gzip budget is not met.
5. Detached DOM nodes on the viewer: **gone** (no server-rendered paths).
6. The footer glow's compositing: **fixed** at tablet and desktop widths
   (change 6); phones keep the blur.
7. Hologram's per-call logging: **reported upstream**; its cost on a
   viewer's stroke is down 25x with change 2.
8. The server: still microseconds; the board's byte cap added, the rest
   measured and left (see "Tried and dropped").

---

# #36: baseline, budgets and the rendering decision

Task #36 (`draw-bench`). Raw results: `bench/results/{server,client}-run{1,2}.json`.
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
