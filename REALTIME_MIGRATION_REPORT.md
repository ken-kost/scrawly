# Scrawly realtime migration — report

Migrating Scrawly's realtime from a custom **Phoenix Channel + poll loop** to
**Hologram v0.9 native realtime** (SSE downstream, HTTP POST upstream), keeping a
thin channel only for the ~20Hz live drawing-chunk stream and disconnect GC.

Branch: `delegate-realtime-to-framework`. Plan: [`REALTIME_MIGRATION_PLAN.md`](REALTIME_MIGRATION_PLAN.md).

Status date: 2026-06-04.

---

## TL;DR

- **Phases 0–4 (the whole hybrid migration) are implemented and compile clean** with
  `mix compile --warnings-as-errors`.
- The **poll loop, the `room_state_changed` PubSub plumbing, the `waiters`/`wait_for_update`
  long-poll machinery, and most of the JS dispatch bridge are deleted.** `RoomServer`
  stays the single source of truth and now broadcasts secret-free deltas straight to
  subscribed pages.
- The Phoenix channel is down to **exactly 3 handlers**: `join`, `drawing_stroke_chunk`,
  `terminate`.
- Verified in the browser (single client): app boots on 0.9.2, home + create-room +
  game lobby render, Hologram hydrates, the realtime broadcast API works, and the
  slimmed channel still joins (`gameSocket.isInRoom() == true`).
- **Not yet done:** multi-client (2+ browser) verification of live chat/state/drawing over
  SSE, the test-suite rewrite, and a few explicitly-deferred polish items (below).
- **Live stroke chunks stay on the channel (2026-11-14):** a measured gate compared the
  demo board's chunk stream over Hologram Realtime with the channel and said no-go (added
  p50 +34 ms at a 100 ms RTT, 3-9x the peer main-thread cost per chunk). See
  [Live stroke chunks: the measured gate](#live-stroke-chunks-the-measured-gate).

---

## What shipped, per phase

### Phase 0 — Upgrade to Hologram v0.9 (no behavior change)
- `mix.exs`: `{:hologram, "~> 0.8"}` → `{:hologram, "~> 0.9.2"}`; resolved to **0.9.2**.
- Verified against the **installed** v0.9 source (not just release notes):
  - **SSE is automatic** via `Hologram.Router` (`GET /hologram/sse`,
    `POST /hologram/sse/handshake`, `POST /hologram/command`), already mounted ahead of
    `ScrawlyWeb.Router` at `endpoint.ex:61` — which is exactly why the 0.9.2 `#811`
    halt-fix matters. **No endpoint/application wiring was needed.**
  - Hologram runs its **own** supervision tree (`Hologram.PubSub`, `SubscriptionRegistry`,
    `Tombstone`, `Handshake`), gated by `Hologram.enabled?()` =
    `env() not in [:dev,:test] or HOLOGRAM_START==1`.
  - `get_session/3` / `put_session/3` remain reachable on the `Server` struct (auth path intact).
- **Zero regressions:** the suite is **288 tests / 23 failures on both v0.8.3 and v0.9.2**
  (verified by running the suite on each). Those 23 are pre-existing test-vs-code drift,
  not the upgrade.
- **Dev/test note:** the realtime runtime only starts with `HOLOGRAM_START=1`. Run the dev
  server with **`mix holo`** (which sets it) instead of `mix phx.server`.

### Phase 1 — Chat → Hologram realtime
- Page subscribes once to `{:room, room_id}` in `GamePage.init/3`.
- New `action(:chat_appended, %{message})`: append + **dedupe by message `id`** + 50-cap +
  autoscroll.
- `RoomServer` broadcasts `:chat_appended` from the **`send_chat_message` choke point** and
  from `GameFlow.add_sys_msg/2` (so join/leave/round system messages fan out too); chat no
  longer nudges a poll (`notify_waiters(false)` for chat).
- Deleted the dead `chat_message` channel handlers.

### Phase 2 — Game/room/timer state deltas (the core deletion)
- `RoomServer.notify_waiters` now broadcasts a **secret-free `:room_delta`** (the public
  slice) instead of the `room_state_changed` poll nudge. **`current_word` / `word_choices`
  are never on the public channel.**
- New `action(:room_delta)`: **Lamport version guard** (drops stale/duplicate deltas),
  applies ambient fields inline (players, status, scores, timer tick), and on a
  **phase/round transition** fires `poll_room_state` **once** to pull the per-user
  masked-word enrichment (keeps `WordHints` server-side).
- Deleted: the recurring poll reschedule; the channel `room_state_changed` handler + `room:`
  subscribe; `Presence.handle_metas` rebroadcast; the redundant `Endpoint.broadcast` in
  `join_room`; the `room_state_changed`/`presence_diff` glue in `game_channel.mjs`; and the
  `waiters`/`wait_for_update` long-poll machinery in `RoomServer`.

### Phase 3 — Persisted drawing (complete / clear / undo) + late-join
- Drawer's `endStroke`/`undoStroke` in `drawing_manager.mjs` now dispatch Hologram actions
  (`:commit_stroke` / `:commit_undo`) instead of channel pushes; `:clear_canvas` issues its
  command. Commands `complete_stroke` / `clear_drawing_cmd` / `undo_drawing_cmd` persist to
  `RoomServer` and `put_broadcast_except({:user, drawer}, {:room, id}, …)`.
- Peers consume `:stroke_completed` / `:drawing_cleared` / `:drawing_undone` (ported from
  the old `receive_*` handlers).
- **Late-join:** peers hydrate from `@drawing_strokes` (read in `init/3`) via the
  `DrawingCanvas` for-loop — now gated on `!is_drawer` so the drawer (JS `strokeHistory`)
  and peers (Hologram `@strokes`) never double-render. A reconnecting **drawer** restores
  its JS history on `channel_connected`. Deleted the `get_drawing_path` channel handler,
  `requestDrawingPath`, and the `sync_full_drawing_path` action.
- **Cross-transport guard:** chunks stay on the channel while completion rides SSE, so a
  late chunk can arrive after completion — `drawing_manager` now tracks `completedStrokeIds`
  and drops trailing chunks instead of resurrecting a ghost overlay.

### Phase 4 — Slim the channel
- `game_channel.ex` reduced to **`join` (auth) + `drawing_stroke_chunk` + `terminate`**
  (abandon-stroke GC). Removed all timer/game/round/drawing-complete/clear/undo/
  `get_drawing_path` handlers, the `game:` PubSub subscribe, and `after_join`/`Presence.track`/
  `presence_state`.
- `game_channel.mjs` reduced to connect/join + chunk apply + abandon GC; removed the dead
  `pushDrawingSegment`/`pushDrawingClear` exports and their `js_import`s.

### Phase 6 — Other v0.9 features (verified; partially adoptable)
- **Keyboard events: NOT in v0.9.2.** Verified against the installed runtime — the bindable
  event set is closed (`$click/$change/$blur/$focus/$submit/$mouse_move/$pointer_*/$select/
  $transition_*`; there is no `$key_down`/`$key_up`). So the plan's keyboard UX was delivered
  via **JS interop** instead: `lib/scrawly_web/pages/keyboard.mjs` installs one document
  `keydown` listener (on `channel_connected`) that dispatches existing actions —
  **Ctrl/Cmd+Z = undo**, **E = eraser** (drawer-only, gated on `#drawing-path`, suppressed
  while typing), and **Escape = clear chat**. Verified in-browser: synthetic key events
  dispatch the right actions and the typing/drawer gates hold. (Enter-to-send already worked
  via the chat form's `$submit`.)
- **Client-side `with`: available** (`transformer.ex` handles `with`/`<-`/`else`), but
  Scrawly's client actions are boolean-guard UI logic with no genuine ok/error chain, so it
  was not forced — it's ready for future ok/error-style client handlers.

---

## Verification

### Automated (done)
- `mix compile --warnings-as-errors` → **green** (only a pre-existing, unrelated
  `LobbyChannel` `presence_diff` `IO.warn`, which does not fail the build).
- Realtime mechanism smoke test: `Scrawly.Realtime.broadcast_action/3` and
  `broadcast_action_except/4` return `:ok` with the runtime **on** (real publish) and
  **off** (guarded no-op). Tests/`mix phx.server` never crash on a broadcast.
- Deletion audit: 0 live `room_state_changed` / `wait_for_update` references in `lib/`
  (only explanatory comments remain); channel = 3 handlers.

### Browser (done, single client, via `mix holo`)
- Home page renders; Hologram client + SSE healthy ("N online" live).
- Create-room modal → **game lobby renders** (exercises `init/3` + `put_subscription`).
- Reload of the game page: no JS console errors, Hologram re-hydrates, room persists,
  and the **slimmed channel joins** (`gameSocket.isInRoom() == true`).

### Manual, multi-client (STILL REQUIRED — needs 2+ browser profiles)
A single browser-driver can't validate cross-client SSE or an active game (needs 2+ players
to start). Run with `mix holo`, two profiles, same room, DevTools Network open to confirm
**SSE frames vs. `poll_room_state` POSTs**:
- **Chat:** A sends → B sees it via an SSE frame, **no `poll_room_state` POST**; system /
  correct-guess messages appear; drawer can't chat.
- **State/timer:** start game; both transition choosing→drawing; timer ticks on both with
  **no per-tick POST**; 3rd client join appears; leave removes; game-end redirects both.
- **Drawing:** drawer's completed stroke renders on B and survives a B reload; clear/undo
  propagate; a 3rd client mid-round sees the full canvas; live chunks still stream ~20Hz;
  drawer closing mid-stroke clears the peer overlay.
- **Spectator:** logged-out/Watcher receives chat/state/strokes via SSE, can't draw, can't
  see the raw word.
- **Reconnect:** drop B's network ~5s, restore → B resyncs full state + canvas.
- **Regression sweep:** lobby room list live; global "N online" still ticks; home demo
  board, auth/profile/score pages render.

### Test suite (deferred, per your call)
`mix test` → **288 tests, 43 failures**: the 23 pre-existing + ~20 from tests that assert on
the now-deleted channel/poll behavior (`game_channel_test`, `game_channel_drawing_test`,
`room_refreshed`-style page tests, channel-broadcast integration tests). This is the
expected ripple the plan calls out; rewriting/porting them (and adding realtime-broadcast,
version-guard, and word-leak assertions) is the remaining test task. A CI workflow
(`.github/workflows/test.yml`, Postgres + `mix test`) was added; it will go green once that
test debt is addressed.

---

## Security note
**Correction:** the original note claimed only `:room_delta` mattered. In fact the word
also leaked through `GamePage.init/3` (page state is serialized into the HTML) and through
every `:room_refreshed` reply (`poll_room_state`, `join_room`, `join_as_watcher`,
`start_game`, `choose_word`), which were built from the raw room state.

Now all of them go through `Scrawly.Games.RoomServer.View`:
- `View.public/1` (`get_state/1`, call replies) and `View.delta/1` (`:room_delta`) never
  contain `current_word`, `word_choices` or `choice_deadline`. They carry `word_display`
  (the `WordHints` mask for the current `time_left`), `word_length` (letters only) and
  `revealed_word` (the word, only in `:round_end`).
- Only `View.for_viewer/2` adds the word and the choices, and only when the viewer is the
  drawer. The viewer is always the session user (`RoomServer.get_view(room_id,
  Auth.user_id(server))`), never a param; account-less visitors are `nil` and never the
  drawer.

The 1 Hz tick's `:room_delta` carries the current mask, so hints reach every client
without a poll and a reload shows the current hint.

---

## Deferred / open items (with reasons)

1. **Multi-client manual verification** — see matrix above. Highest priority before merge.
2. **Test-suite rewrite** — port the channel/poll tests to realtime assertions; add
   version-guard, word-leak, and producer-broadcast coverage. (You deferred this.)
3. **Progressive hint reveal** — done: the 1Hz `:room_delta` carries the current mask
   (`word_display`), computed server-side. Never send a reveal schedule or letter positions:
   they would let a client read letters early.
4. **Hard-disconnect player removal** — `terminate` intentionally does **not** call
   `RoomServer.leave` (it would dissolve the room on creator reload and cause leave/rejoin
   flicker). Disconnected players already lingered before this migration (presence only
   nudged a poll), so this is no regression; a correct version needs a reconnect grace period.
5. **Legacy JS dead code** — done: `assets/js/user_socket.js` and the `app.js`
   chat-integration block were deleted (post-upgrade hygiene), and the senders of
   `priv/static/game_socket.js` that GameChannel has no handler for (`sendDrawingSegment`,
   `sendDrawingStroke`, `sendDrawingStrokeComplete`, `sendDrawingClear`, `sendDrawingUndo`,
   `requestDrawingPath`, the `onDrawing*` stubs) were deleted with the gate below.
6. **Phase 0 polish** — the broad `@impl true` sweep and `mix holo.gen.claude_md` AI-rules
   regen were skipped as low-value (the v0.9 compiler already validated the build).
7. **Keyboard follow-ups** — undo / eraser / escape-clear shipped via JS interop (Phase 6);
   the bracket brush-size shortcut was skipped (needs current-width stepping). Swap the
   interop bridge for native `$key_down` bindings if/when a later Hologram release adds them.

## Live stroke chunks: the measured gate

Board task #21 (chunk-stream-migration), 2026-11-14. **Decision: no-go.** The live
in-progress stroke chunks of the demo board and the game stay on the hardened Phoenix
channels (`demo:board`, `game:*`), and with them `UserSocket`, `socket "/socket"`,
`phoenix.min.js` and `game_socket.js`. Everything else is already on Hologram Realtime.

### What was compared

- **Realtime prototype** of the demo board, built next to the channel and switchable at
  runtime (same stroke engine, same 50 ms minimum chunk interval, same store): each chunk
  a `:demo_stroke_chunk` command dispatched from JS, **ack-paced** (the next chunk goes only
  after `:demo_chunk_acked`, so one chunk command per drawer is in flight and a drawer's
  chunks stay in order), validated and rate-limited per `Auth.actor_key/1` (ETS GenServer),
  relayed with `put_broadcast_except({:instance, id}, :demo_board, :demo_chunk_in, ...)`;
  completed strokes and clear as commands, `DemoBoardServer` broadcasting
  `:demo_stroke_added` / `:demo_board_cleared`, the snapshot loaded by a command after
  mount, an idle sweep for orphaned overlays. It worked end to end (live strokes,
  completed strokes, clear and snapshot over SSE) and was removed again after the gate.
- **Server:** a local prod release (`MIX_ENV=prod`) of the working tree. The dev server is
  not usable for this: `Phoenix.CodeReloader` adds ~35-40 ms to every HTTP request (a
  command round trip measured 35-42 ms there, 1.4-2 ms on the release), while WebSocket
  frames skip the plug pipeline. On the dev server Realtime measured p50 93 / p95 122 ms
  against the channel's 51 / 83 ms (N=2).
- **Network:** (a) HTTP/1.1 direct; (b) TLS with HTTP/2 through a local reverse proxy
  (page, commands and SSE on h2; the WebSocket on HTTP/1.1 through the same proxy);
  (c), (d) the same behind a TCP proxy delaying every byte 50 ms each way (RTT +100 ms for
  WebSocket frames, SSE events and POSTs alike, which DevTools throttling is not
  guaranteed to do for frames of an already open stream).
- **Clients:** headless Chromium 139, one browser process per client, real (CDP) mouse
  input at 60 Hz. N=2: 1 drawer, 1 peer, 4 strokes of 150 moves. N=8: 3 drawers drawing at
  the same time, 5 peers, 3 strokes of 150 moves each. Also peers on a 4x slower CPU
  (CDP CPU throttling).
- **Metrics:** latency from the drawer's `pointermove` that emits a segment to the
  animation frame in which the peer's overlay path holds it (DOM probe; each browser's
  clock aligned to the harness's). Peer cost: main-thread task time
  (`Performance.TaskDuration`) during the session minus idle, per chunk received. Drawer
  cost: the drawer's main-thread time over the session. Backlog: chunk commands in flight
  (CDP Network), chunks per second, stroke-end lag (drawer commit to the peer's stored
  stroke).

### Results

Latency in ms, p50 / p95 (third run, clock-aligned; the first run agrees within a few ms):

| network | clients | channel | Realtime | added p50 / p95 |
|---|---|---|---|---|
| HTTP/1.1 | 2 | 46.4 / 64.0 | 46.3 / 78.9 | -0.1 / +14.9 |
| TLS + HTTP/2 | 2 | 45.7 / 77.7 | 47.3 / 79.9 | +1.6 / +2.2 |
| HTTP/1.1, RTT +100 | 2 | 146.4 / 176.9 | 179.9 / 229.6 | **+33.5** / +52.7 |
| TLS + HTTP/2, RTT +100 | 2 | 146.6 / 178.4 | 181.8 / 230.5 | **+35.2** / +52.1 |
| HTTP/1.1 | 8 | 56.7 / 86.7 | 73.4 / 158.3 | +16.7 / +71.6 |
| TLS + HTTP/2 | 8 | 57.6 / 87.8 | 83.7 / 170.4 | +26.1 / +82.6 |
| HTTP/1.1, RTT +100 | 8 | 159.0 / 190.0 | 214.5 / 279.5 | **+55.5** / +89.5 |
| TLS + HTTP/2, RTT +100 | 8 | 161.3 / 192.1 | 219.8 / 283.0 | **+58.5** / +90.9 |

Without added latency both are dominated by the 50 ms chunk interval (a local command
round trip is 3-5 ms at N=2, 11-17 ms at N=8).

Backlog and update rate, per drawer:

| | channel | Realtime |
|---|---|---|
| chunk commands in flight (max) | - | 1 in every run |
| chunks per second, no added latency | 16-18 | 17.3 (N=2), 14.5-14.9 (N=8) |
| chunks per second, RTT +100 | 16-18 | **8.2 (N=2), 6.9-7.1 (N=8)** |
| stroke-end lag, N=2 | 1-2.5 ms (103 ms at RTT +100) | 20 ms (123-125 ms at RTT +100) |

There is no queue (ack pacing never lets one build up), but under latency a chunk waits
for the previous one's ack, so peers get half as many updates, each about twice as long:
the live line advances in coarser steps.

Main-thread cost:

| | channel | Realtime |
|---|---|---|
| peer, per chunk, home page, N=2 | 1.2-1.6 ms | 4.3-5.1 ms |
| peer, per chunk, home page, N=8 (3 drawers) | 1.2-1.3 ms | 10.6-11.7 ms |
| peer, per chunk, 4x slower CPU (N=2 / N=4) | 4.5 / 5.5 ms | 17.6 / 23.8 ms |
| drawer, per session, N=2 | 1.2-1.6 s | 2.6 s |
| drawer, per session, N=8 (also receives 2 drawers) | 1.9-2.0 s | 17.2-18.5 s |
| one pushed action, game page viewer with 100 strokes | - | 5.2 ms (24.3 ms at 4x CPU) |

Every pushed action runs a full `Hologram.render()` of the page (the action itself takes
~0.3 ms), and every chunk costs the drawer a dispatched action plus its ack action, each
with a render. On a game page at ~16 chunks/s that is ~8% of a desktop main thread and
~40% of a 4x slower device's, per drawer; the channel writes one `d` attribute. Server
side, every chunk is an HTTP request through the page middleware (home page: 2 SELECTs per
chunk for a signed-in user; the game page's `:id_only` middleware: 1), where a channel
frame costs none.

### Decision

The spec's threshold was: go if the added p50 is at most ~30 ms, with no backlog, a peer
cost no higher than the channel's, and smooth drawing. Realtime matches the channel only
without network latency. At a realistic RTT it adds 34-35 ms p50 (N=2) and 55-59 ms (N=8),
halves the update rate, and costs peers 3-9x the channel's main-thread time per chunk.
So **no-go**: the hardened channels stay (task #5's GameChannel membership and drawer
checks, task #11's DemoBoardChannel validation and limits), and the dead senders of
`game_socket.js` are gone. Worth revisiting when Hologram can deliver a pushed action to
JS without a full page render, and pipeline commands without waiting for each reply.

Measurement caveats: one machine (16 threads, WSL2) runs every client, so N=8 numbers
include CPU contention (it inflates Realtime's render-heavy path more). A browser process
there sometimes starts with its clock 0.7-1 s off; the harness aligns clocks (the second
run had no alignment yet, and its three N=8 runs with such an offset are not used).

---

## Key files touched
- `lib/scrawly/realtime.ex` — **new**: guarded wrapper (no-ops when the runtime is off).
- `lib/scrawly/games/room_server.ex` — `:room_delta` / `:chat_appended` broadcasts;
  `public_delta/1`; removed `waiters`/`wait_for_update`.
- `lib/scrawly/games/room_server/game_flow.ex` — system messages fan out via `:chat_appended`.
- `lib/scrawly_web/pages/game_page.ex` — subscription in `init/3`; `:room_delta`,
  `:chat_appended`, `:commit_stroke`, `:commit_undo`, `:stroke_completed`, `:drawing_cleared`,
  `:drawing_undone`; reconnect hydrate.
- `lib/scrawly_web/pages/game_page/commands.ex` — `complete_stroke` / `clear_drawing_cmd` /
  `undo_drawing_cmd`; removed the redundant `Endpoint.broadcast`.
- `lib/scrawly_web/pages/drawing_manager.mjs` — dispatch Hologram actions on
  complete/undo; `completedStrokeIds` ordering guard.
- `lib/scrawly_web/pages/game_channel.mjs` — chunk + abandon only.
- `lib/scrawly_web/pages/keyboard.mjs` — **new**: JS-interop keyboard shortcuts (Phase 6).
- `lib/scrawly_web/channels/game_channel.ex` — slimmed to join/chunk/terminate.
- `lib/scrawly_web/channels/presence.ex` — game-channel rebroadcast dropped; lobby counter kept.
- `lib/scrawly_web/components/drawing_canvas.ex` — for-loop gated on `!is_drawer`.
- `mix.exs` — Hologram `~> 0.9.2`.
- `.github/workflows/test.yml` — **new**: CI.
