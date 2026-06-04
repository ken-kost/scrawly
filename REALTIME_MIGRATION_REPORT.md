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
The `:room_delta` payload (`RoomServer.public_delta/1`) **omits `current_word` and
`word_choices`**. Non-drawers never receive the raw word on the public `{:room, id}`
channel; the masked display is computed server-side by `WordHints` via each user's own
`poll_room_state` on a transition. (For v1 this uses "option A" — see deferred items.)

---

## Deferred / open items (with reasons)

1. **Multi-client manual verification** — see matrix above. Highest priority before merge.
2. **Test-suite rewrite** — port the channel/poll tests to realtime assertions; add
   version-guard, word-leak, and producer-broadcast coverage. (You deferred this.)
3. **Progressive hint reveal (option B)** — with option A, the masked word updates at
   phase/round boundaries, not every tick. Drawing/round timers stay smooth (1Hz delta).
   If per-tick letter reveal matters, broadcast a precomputed reveal schedule.
4. **Hard-disconnect player removal** — `terminate` intentionally does **not** call
   `RoomServer.leave` (it would dissolve the room on creator reload and cause leave/rejoin
   flicker). Disconnected players already lingered before this migration (presence only
   nudged a poll), so this is no regression; a correct version needs a reconnect grace period.
5. **Legacy JS dead code** — `assets/js/user_socket.js`, the `app.js` chat-integration block,
   and unused senders in `priv/static/game_socket.js` are now dead (the live drawing socket
   is `window.gameSocket`). Harmless; left for a focused JS hygiene pass.
6. **Phase 0 polish** — the broad `@impl true` sweep and `mix holo.gen.claude_md` AI-rules
   regen were skipped as low-value (the v0.9 compiler already validated the build).
7. **Keyboard follow-ups** — undo / eraser / escape-clear shipped via JS interop (Phase 6);
   the bracket brush-size shortcut was skipped (needs current-width stepping). Swap the
   interop bridge for native `$key_down` bindings if/when a later Hologram release adds them.

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
