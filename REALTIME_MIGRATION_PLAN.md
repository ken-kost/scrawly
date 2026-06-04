# Migrate Scrawly realtime → Hologram v0.9 native realtime (hybrid)

## Context

Hologram [v0.9.0](https://github.com/bartblast/hologram/releases/tag/v0.9.0) shipped a **native realtime pub/sub layer**: a server (or any Elixir process) can push an *action* to subscribed page/component instances, delivered to the existing `action/3` callback — pure Elixir, no JS, no polling. Transport is HTTP POST upstream + SSE downstream (no WebSocket); semantics are fire-and-forget (at-most-once, no ordering, no replay — same as `Phoenix.PubSub`); it has **no built-in authorization and no presence/disconnect detection**.

Scrawly (a Skribbl-style multiplayer drawing game) currently implements realtime with a **custom hybrid that exists only because v0.8 had no realtime**: a Phoenix Channel ([game_channel.ex](lib/scrawly_web/channels/game_channel.ex)) + a JS bridge ([game_channel.mjs](lib/scrawly_web/pages/game_channel.mjs), [user_socket.js](assets/js/user_socket.js)) that turns every channel event into `globalThis.Hologram.dispatchAction("poll_room", …)`. **The entire state path is a poll loop**: any `RoomServer` mutation → PubSub `:room_state_changed` → channel push → JS `poll_room` → command `poll_room_state` → action `:room_refreshed` rewrites all page state. The branch name `delegate-realtime-to-framework` captures the goal: hand this plumbing to the framework.

**This is the right move where it maps, but not everywhere.** The ~20Hz live drawing-stroke stream deliberately bypasses the framework's render path (peers apply chunks via direct JS, no dispatch — [game_channel.mjs:48](lib/scrawly_web/pages/game_channel.mjs#L48)), and abandon-stroke-on-disconnect + presence rely on the channel's connection lifecycle, which Hologram realtime lacks.

**Decisions taken (with the user):**
- **End-state = hybrid.** Migrate all state/event sync to Hologram realtime; keep a *thin* Phoenix channel ONLY for the 20Hz chunk stream + disconnect/abandon detection.
- **First pass = full hybrid migration.** Phases 0–4 below: upgrade, then migrate chat, game/room/timer state, and stroke-complete/clear/undo + late-join sync, slimming the channel to chunks.

**Outcome:** delete the poll loop, the `room_state_changed` PubSub plumbing, and ~all of the JS dispatch bridge; the server broadcasts real deltas straight to subscribed pages. `RoomServer` stays the source of truth.

> ⚠️ Scrawly is on `{:hologram, "~> 0.8"}` (lock = 0.8.3). v0.9 is real, unstarted work, and should land on the **latest 0.9.x (≥ 0.9.2)** — see Phase 0 for why the patch level matters here. Several v0.9 specifics (SSE wiring, `mix holo` dev start, callback/@impl churn, session access + reconnect hooks in realtime callbacks) were researched from release notes/forum/changelog, not from installed code — every item tagged **[VERIFY]** must be confirmed against the official v0.9 upgrade guide while doing Phase 0.

## Findings that shape the plan (verified in code)

- **The poll loop is the sole state path.** `RoomServer.notify_waiters/1` ([room_server.ex:808](lib/scrawly/games/room_server.ex#L808)) is the single choke point every mutation funnels through; it broadcasts `:room_state_changed`. The comment at [game_page.ex:192](lib/scrawly_web/pages/game_page.ex#L192) claiming a "channel pushes full state → channel_state_update" path is **false** — no such action exists.
- **`online_count` is lobby-driven and OUT OF SCOPE.** `Presence.online_count/0` ([presence.ex:34](lib/scrawly_web/channels/presence.ex#L34)) lists the `"lobby:rooms"` topic (populated by `LobbyChannel`), polled by [app_layout.ex](lib/scrawly_web/layouts/app_layout.ex). The game channel's own presence has no consumer except the poll nudge. Migrating game realtime does **not** touch the lobby or the global counter.
- **`enrich_state/2` ([commands.ex:244](lib/scrawly_web/pages/game_page/commands.ex#L244)) computes per-user fields the browser can't** — word masking via `WordHints`, drawer name, `choice_time_left` — and **strips strokes** on poll ([commands.ex:304](lib/scrawly_web/pages/game_page/commands.ex#L304)). The word-hint masking is the one sharp edge for delta broadcasts (must never put the raw word on a channel non-drawers subscribe to).
- **Spectators already use a second transport:** logged-out/`"Watcher"` sessions long-poll every 3s ([game_page.ex:259](lib/scrawly_web/pages/game_page.ex#L259)) because they have no socket token and never open the channel.
- **Two disconnect signals, one connection-coupled:** `Presence.handle_metas` → poll (replaceable by mutation deltas) and `GameChannel.terminate/2` ([game_channel.ex:403](lib/scrawly_web/channels/game_channel.ex#L403)) → `drawing_stroke_abandon` (genuinely needs the socket lifecycle).
- **`RoomServer` has a monotonic `version`** bumped per mutation — reused below as an ordering guard.

## Target architecture (hybrid)

- **One subscription per page:** `put_subscription(server, {:room, room_id})` in [game_page.ex](lib/scrawly_web/pages/game_page.ex) `init/3` carries all public room deltas. The current **drawer** additionally subscribes to identity channel `{:user, user_id}` for drawer-only secrets (raw word / `word_choices`).
- **Producers:** `RoomServer` broadcasts state/chat/timer deltas from its mutation choke point via `Hologram.Realtime.broadcast_action({:room, id}, …)`; `GamePage` commands broadcast drawing-complete/clear/undo via `put_broadcast_except`.
- **Thin Phoenix channel stays** for `drawing_stroke_chunk` (20Hz) + `terminate` abandon only.
- **`RoomServer` stays authoritative**; broadcasts are projections of just-committed state.

### Per-feature mapping

| Feature (today) | Channel | Subscribe site | Delta action(params) | Producer | Deleted |
|---|---|---|---|---|---|
| Chat message added | `{:room, id}` | `init/3` (once) | `:chat_appended %{message}` | `RoomServer` send_chat_message handler → `broadcast_action_except` | dead `chat_message/*` ([game_channel.ex:181](lib/scrawly_web/channels/game_channel.ex#L181)); `sendChatMessage`/`onChatMessage` |
| Player join / leave | `{:room, id}` | (same) | `:room_delta` (players, version, status) | `RoomServer.notify_waiters` | `Presence.handle_metas` rebroadcast; [commands.ex:37](lib/scrawly_web/pages/game_page/commands.ex#L37) endpoint.broadcast; `presence_diff`→poll |
| Game start / end | `{:room, id}` | (same) | `:room_delta` (game_id, phase, round) | `RoomServer.notify_waiters` | dead `start_game`/`end_game` channel handlers |
| Round / phase change | `{:room, id}` | (same) | `:room_delta` (+ targeted enrich for word mask) | `RoomServer.notify_waiters` | dead `round_start`/`turn_change` handlers |
| Timer tick (1Hz) | `{:room, id}` | (same) | `:room_delta` (time_left) | `RoomServer.handle_info(:timer_update)` → `notify_waiters` | per-tick `room_state_changed`→poll; channel timer pushes |
| Word-choice phase | `{:room, id}` + `{:user, drawer}` | (same) | `:room_delta` (phase, choice_deadline); `word_choices` to drawer only | `RoomServer` choose_word / timeout | n/a (was poll) |
| Stroke completed | `{:room, id}` | (same) | `:stroke_completed %{stroke_id,path,color,width}` | command `:complete_stroke` → `put_broadcast_except` (drawer `{:user,id}`) | `drawing_stroke`/`_complete` channel + mjs + socket senders |
| Clear canvas | `{:room, id}` | (same) | `:drawing_cleared %{}` | command `:clear_drawing_cmd` → `put_broadcast_except` | `drawing_clear` channel + mjs |
| Undo | `{:room, id}` | (same) | `:drawing_undone %{strokes}` | command `:undo_drawing_cmd` → `put_broadcast_except` | `drawing_undo` channel + mjs |
| Late-joiner full canvas | n/a (init load) | — | init `:hydrate_canvas` `JS.call(:setStrokes,[strokes])` | read RoomServer in `init/3` | `get_drawing_path` channel; `requestDrawingPath`; `sync_full_drawing_path` action |
| **Live chunk (~20Hz)** | **Phoenix channel (KEPT)** | — | JS-only `applyRemoteChunk` | channel `broadcast_from` | nothing |
| **Abandon on disconnect** | **Phoenix channel (KEPT)** | — | JS-only `abandonRemoteStroke` | `GameChannel.terminate` | nothing |
| Global online count | `lobby:rooms` (unchanged) | OUT OF SCOPE | unchanged | LobbyChannel | nothing |

## Phasing (app stays green and shippable at every step)

### Phase 0 — Upgrade to v0.9, no behavior change
- Bump [mix.exs](mix.exs) to `{:hologram, "~> 0.9"}` and resolve to **≥ 0.9.2**; `mix deps.get`; `mix deps.update hologram`. The patch level matters specifically for Scrawly:
  - **0.9.2 (#811)** fixes the SSE response not being halted (`Plug.Conn.AlreadySentError`) **when `Hologram.Router` is mounted ahead of another router** — which is exactly our [endpoint.ex:61-62](lib/scrawly_web/endpoint.ex#L61-L62) (`plug Hologram.Router` then `plug ScrawlyWeb.Router`). On < 0.9.2 enabling SSE realtime would crash. **This is the gating reason to pin ≥ 0.9.2.**
  - **0.9.2 (#813)** fixes `Hologram.Router` raising a "no persistent term" error when Hologram is disabled, which otherwise breaks `mix test` — relevant since tests run with Hologram not started (below).
  - **0.9.1 (#809)** removes the Biome formatter from the compiler, fixing exponentially slow compilation on deeply nested templates ([game_page.ex](lib/scrawly_web/pages/game_page.ex) is large).
  - **0.8.3** already fixed a bundle-size explosion affecting Ash apps — confirm bundle size is sane post-upgrade since Scrawly is Ash-heavy.
- **[VERIFY] against the official upgrade guide and action:** auto-start removal in dev/test (wire `mix holo` / the opt-in env var into the dev workflow, [config/dev.exs](config/dev.exs) watchers, and [config/test.exs](config/test.exs)/CI); **SSE downstream transport** wiring in [endpoint.ex](lib/scrawly_web/endpoint.ex) and/or a `Hologram.Realtime` child in [application.ex](lib/scrawly/application.ex); callback/`@impl` signature changes and `put_action`/`put_command` now accepting maps; that `get_session/2` remains reachable in `init/3` and `command/3` (needed for auth in later phases).
- **Add `@impl true`** to `action/3` and `command/3` across **all** pages/components (home, lobby, profile, score, layout, game) — v0.9 makes these optional callbacks the compiler can verify, so this catches typo'd action/command clause names (valuable given [game_page.ex](lib/scrawly_web/pages/game_page.ex) has dozens of `action/3` clauses). Sweep any other callback/signature changes here too.
- **Regenerate the project's AI rules** with `mix holo.gen.claude_md` (and/or `holo.gen.agents_md`) so [usage-rules/](usage-rules/) and the Hologram section of [CLAUDE.md](CLAUDE.md) pick up v0.9's realtime conventions — these guide every later phase. **[VERIFY]** task name in v0.9.
- **Migrate nothing** — everything still runs on channel + poll.
- **Exit:** `mix compile --warning-as-errors` and `mix test` green (fix only compile-level breakage); app boots; existing multiplayer flow works exactly as before. Commit.

### Phase 1 — Chat (smallest, highest-signal slice)
- **Subscribe** `{:room, room_id}` once in [game_page.ex](lib/scrawly_web/pages/game_page.ex) `init/3` (players, watchers, and anonymous spectators may all subscribe — payloads are public).
- **Broadcast at the mutation site:** add `Hologram.Realtime.broadcast_action_except(<sender>, {:room, id}, :chat_appended, %{message: msg})` inside `RoomServer`'s `send_chat_message` handler ([room_server.ex:557](lib/scrawly/games/room_server.ex#L557)) so user, system, and correct-guess messages (which all route through it from [commands.ex:155](lib/scrawly_web/pages/game_page/commands.ex#L155) / [commands.ex:166](lib/scrawly_web/pages/game_page/commands.ex#L166)) fan out.
- **New action** `:chat_appended` appends to `chat_messages` (mirror the chat branch inside `:room_refreshed`, [game_page.ex:253](lib/scrawly_web/pages/game_page.ex#L253)), keeps the 50-cap, and triggers the existing scroll. Sender keeps its optimistic local append → use `broadcast_action_except` and/or dedupe by message `id` to avoid double-apply.
- **Keep the send path** (`action(:send_message)` → `put_command(:send_chat_message)`); only the fan-out moves to realtime. Self-echo piggybacks the sender's broadcast on its POST.
- **Delete** the dead `chat_message` channel handlers and the `sendChatMessage`/`onChatMessage` socket methods.
- **Exit:** two browsers, same room — A sends, B sees it with an SSE frame and **no `poll_room_state` POST**. Commit.

### Phase 2 — Game / room / timer state deltas (the core deletion)
- **One broadcast at the choke point:** replace the `:room_state_changed` PubSub in `RoomServer.notify_waiters/1` ([room_server.ex:808](lib/scrawly/games/room_server.ex#L808)) with `Hologram.Realtime.broadcast_action({:room, id}, :room_delta, public_payload)`. `public_payload` = the **public** slice (players, watchers, status, **version**, game_id, current_round, total_rounds, current_drawer_id, time_left, phase, correct_guessers, choice_deadline). **Never** include the raw `current_word` for non-drawers (see Auth).
- **Timer ticks ride through unchanged:** `RoundTimer` already feeds `RoomServer.handle_info(:timer_update)` → `notify_waiters`, so the new `:room_delta` fires once/sec with `time_left`. This deletes the per-tick poll round-trip. Keep [round_timer.ex](lib/scrawly/games/round_timer.ex) as-is; broadcast only through RoomServer (single ordered producer).
- **New action `:room_delta`:** port the body of `action(:room_refreshed)` + `handle_game_state_changes/2` ([game_page.ex:217](lib/scrawly_web/pages/game_page.ex#L217), [game_page.ex:558](lib/scrawly_web/pages/game_page.ex#L558)) to consume the delta map (largely a rename; keep the game-end → `put_page(GameScorePage)` redirect). Apply the **version guard** (drop deltas with `version <= state.version`).
- **Word masking on transitions:** when the page sees `phase`/`round` change, fire the existing `poll_room_state` command **once** (not per tick) to pull its per-user enriched slice (`enrich_state` keeps `WordHints` server-side). Recommended v1; tradeoff noted in Open decisions.
- **Delete:** `notify_waiters` PubSub; `GameChannel.handle_info(:room_state_changed)` + the `room:` subscribe ([game_channel.ex:21](lib/scrawly_web/channels/game_channel.ex#L21)); `Presence.handle_metas` rebroadcast body ([presence.ex:17](lib/scrawly_web/channels/presence.ex#L17)); the redundant `Endpoint.broadcast` in `join_room` ([commands.ex:37](lib/scrawly_web/pages/game_page/commands.ex#L37)); the `room_state_changed`/`presence_diff`/`channel_connected`→poll glue in [game_channel.mjs](lib/scrawly_web/pages/game_channel.mjs); and the now-unused `waiters`/`wait_for_update` long-poll machinery in `RoomServer`.
- **Keep `poll_room_state`/`enrich_state`** as the initial-enrich + per-transition-mask + reconnect-resync path (do NOT delete the command — only the per-event poll *loop*).
- **Exit:** two+ browsers — start game, advance rounds, timer counts down on both with no per-tick POST; join/leave updates peers; game-end redirects both. Commit.

### Phase 3 — Persisted drawing (complete / clear / undo) + late-join sync
- **Stroke complete:** drawer's `endStroke()` issues a Hologram command `:complete_stroke` → `RoomServer.append_drawing` + `put_broadcast_except(server, {:user, drawer_id}, {:room, id}, :stroke_completed, %{…})`. Peers' `action(:stroke_completed)` = today's `receive_drawing_stroke_complete` body (`JS.call(:removeRemoteOverlay)` + append). Excepting the drawer's identity avoids echoing the stroke they already rendered locally.
- **Clear / Undo:** `:clear_canvas` / `:undo_drawing` → commands `:clear_drawing_cmd` / `:undo_drawing_cmd` → `RoomServer.clear_drawing` / `undo_drawing` + `put_broadcast_except(:drawing_cleared / :drawing_undone)`. Peers reuse `receive_drawing_clear` / `receive_drawing_undo`.
- **Late-joiner sync → init load:** `init/3` already reads `rs.drawing_strokes`; queue an action `:hydrate_canvas` doing `JS.call(:setStrokes, [strokes])`. Deletes the `get_drawing_path` channel handler, `requestDrawingPath`, and the `sync_full_drawing_path` action entirely.
- **Delete** the corresponding channel handlers, mjs handlers, and `user_socket.js` senders; rewire [drawing_manager.mjs](lib/scrawly_web/pages/drawing_manager.mjs) `endStroke`/`clearDrawing`/`undoStroke` to issue the new commands instead of `gs.send*`.
- **After Phase 3, only `drawing_stroke_chunk` + `terminate` remain on the channel.**
- **Exit:** drawer draws → completed stroke appears on peer and survives a peer reload (init hydrate); clear/undo propagate; a 3rd client joining mid-round sees the full canvas. Commit.

### Phase 4 — Slim the channel
- Reduce [game_channel.ex](lib/scrawly_web/channels/game_channel.ex) to `join` (auth), `handle_in("drawing_stroke_chunk")`, and `terminate`. Drop all timer/game/round handlers, the game/room PubSub subscriptions, and `after_join`/`Presence.track`/`presence_state` (no consumer remains). Have `terminate` *also* call `RoomServer.leave`/`handle_player_disconnect` so a hard-dropped player is removed and a `:room_delta` follows — reusing the lifecycle signal already kept for abandon, with no new heartbeat.
- Slim [user_socket.js](assets/js/user_socket.js) to chunk senders + connect/join/leave; remove the dead callback registry. Slim [game_channel.mjs](lib/scrawly_web/pages/game_channel.mjs) to connect/join + chunk apply + abandon GC. Spectators never connect (can't draw).
- **Exit:** behavior identical; channel is ~3 handlers. Commit.

### Phase 5 — (Out of scope by decision) chunk hot path stays on the channel
Per the decision to keep a thin channel, the 20Hz chunk stream remains on Phoenix and is **not** migrated. If ever revisited, gate it behind a perf spike (measure POST-per-flush backlog, end-to-end chunk latency vs. the channel baseline, and per-chunk main-thread cost under throttled network); bar to migrate = ≤~30ms added median latency, no flush backlog, peer cost ≤ channel. Note: full migration would also force a worse *timeout-based* stale-overlay sweep for abandon (no disconnect hook) — a standing reason to keep the channel.

## Other v0.9 features to adopt (beyond realtime)

The release is "Realtime **and more**". Beyond the pub/sub layer, fold these in (confidence labels: **Verified** = corroborated across release notes/changelog; **[VERIFY]** = inferred from issue/PR refs, confirm against v0.9 docs before relying on it):

- **(Verified — in Phase 0) Pin ≥ 0.9.2 + `mix holo`/no-auto-start + `@impl` callbacks + regenerate AI rules.** Covered above; these are not optional — the SSE/router-ordering fix and the `mix test` fix are prerequisites for the migration to run at all.
- **(Verified — low effort) `put_action`/`put_command` accept maps.** Use `%{...}` params for the new delta/broadcast actions (`:room_delta`, `:stroke_completed`, …) where it reads more cleanly than keyword lists. Purely ergonomic; no behavior change.
- **([VERIFY] — opt-in, genuinely useful) Keyboard events** (`$key_down`/`$key_up`, inferred from issue #808; today's [usage-rules/events.md](usage-rules/events.md) lists only pointer/mouse/form events, so this would be new). If available in v0.9, adopt in a small follow-up after the core migration:
  - [chat_box.ex](lib/scrawly_web/components/chat_box.ex): **Enter to send / Escape to clear** instead of relying solely on `$submit`.
  - [drawing_canvas.ex](lib/scrawly_web/components/drawing_canvas.ex): **Ctrl/Cmd+Z = undo**, **E = eraser**, bracket keys = brush size — these currently have no keyboard path. Gate on `is_drawer`.
  - Confirm the exact event names, the `params.event` shape (`key`/`code`/modifier booleans), and that key events don't fire on the excluded modifier combos noted in events.md.
- **([VERIFY] — optional, cosmetic) Client-side `with` special form** (PRs #738/#805). Lets action handlers use `with {:ok, _} <- … else …` in the browser. Candidates: the `:send_message` correct-guess chain and the canvas pointer guards in [game_page.ex](lib/scrawly_web/pages/game_page.ex). Pure readability; do opportunistically, not as its own task.
- **(Skip for now) New Erlang stdlib JS ports** (`binary_to_term/1`, `map_get/2`, `iolist_to_binary/1`). No concrete need in Scrawly's app code; ignore unless a specific encoding need arises.

None of these change the migration's shape — they ride along Phase 0 (the mandatory ones) or land as small follow-ups (keyboard events, `with`). Treat the [VERIFY] items as nice-to-haves contingent on the v0.9 docs, not commitments.

## Source of truth, ordering, resync

- **Broadcast deltas, not nudges.** A nudge re-incurs the poll round-trip we're deleting; the broadcast is a projection of just-committed `RoomServer` state, produced inside the mutating `handle_call`.
- **Ordering despite no guarantees:** carry `version` in every `:room_delta`; the page **drops any delta with `version <= state.version`** (Lamport guard) — makes duplicate/out-of-order delivery safe. `handle_game_state_changes` is already **level-triggered** (targets computed from absolute `game_id`/`current_round`/`phase`), so a lost intermediate delta self-heals on the next one. Timer ticks are monotonic-down — a dropped tick is invisible.
- **Resync after SSE reconnect (no replay):** on reconnect (**[VERIFY]** v0.9 exposes a connect/reconnect hook; if not, add a low-frequency safety poll), fire one `poll_room_state` to overwrite local state and re-run `:hydrate_canvas` to restore completed strokes from truth. This is why `poll_room_state` is kept.

## Authorization (none built-in — all checks are ours)

- **Subscribe-time, in `init/3` before `put_subscription`:** members, watchers, and anonymous spectators may subscribe to public `{:room, id}` (safe — no secrets ride it). **Only the current drawer** also subscribes to `{:user, user_id}` for the raw word / `word_choices`. Anonymous users get a synthetic spectator identity and never a `{:user, id}` channel. Unknown/dissolved room → existing `put_page(HomePage)`.
- **Broadcast-time:** `RoomServer` mutations remain the authoritative gate (`:not_drawer`, `:not_choosing`, `:room_full`, creator-presence); commands broadcast only if the mutation succeeded. Drawer-secret broadcasts are addressed to exactly the drawer's identity.
- **Spectators move from the 3s long-poll to SSE subscription** (strictly better); delete the poll-fallback branch at [game_page.ex:259](lib/scrawly_web/pages/game_page.ex#L259). **[VERIFY]** SSE auto-connects for pages without a logged-in session.

## Presence / disconnect decision

**Keep `GameChannel.terminate` for abandon-stroke GC; drop Phoenix.Presence from the game channel; add no heartbeat.** The global counter is lobby-driven and untouched. "Player left" is covered by the explicit `:leave_room` delta; hard disconnects are caught by reusing `terminate` (Phase 4) to also remove the player and emit a delta. Abandon-stroke must stay connection-coupled (Hologram has no disconnect hook), so `open_stroke_ids` + `terminate` → `drawing_stroke_abandon` + peer `abandonRemoteStroke` stay as-is.

## Risks & open items

- **v0.9 upgrade churn [VERIFY all]:** dev/test auto-start removal, SSE wiring, callback/@impl sweep across every page/component, `mix.exs` `compilers:`/`listeners:` shape.
- **Progressive hint reveal regression (masking option A):** non-drawer letter reveal updates at phase/round boundaries instead of every tick. If unacceptable, implement option B (broadcast a precomputed reveal schedule to non-drawers and reveal client-side per tick) before shipping Phase 2.
- **Chat is a non-idempotent append:** a dropped `:chat_appended` loses a message until the next resync (mitigated by reconnect snapshot + 50-cap; optional self-heal by including `chat_messages` in periodic deltas).
- **Self-echo double-apply:** use `*_except` with the sender/drawer identity and dedupe by `id`.
- **Tests:** the channel/poll deletions ripple through the suite, and the new realtime paths need fresh coverage — see the dedicated **Tests** section below.

## Tests: improve & expand

The suite today is solid on domain logic (~28 files; thorough `scoring_test.exs`, `word_test.exs`, `word_hints_test.exs`, game/room/user lifecycle, and multi-player integration flows) but ties its **realtime** coverage to the Phoenix channel + poll plumbing that this migration deletes, and has real gaps the migration makes riskier (delta ordering, word-leak, watcher path, hard-disconnect). Reuse the existing tooling: `Phoenix.ChannelTest` via [test/support/channel_case.ex](test/support/channel_case.ex), `Scrawly.DataCase` (Ash sandbox), the `WordHints` unit tests, and the established **pure `action/3`-called-directly** page-test style ([test/scrawly_web/pages/game_page_test.exs](test/scrawly_web/pages/game_page_test.exs)).

### Test tooling changes (do in Phase 0)
- **`mix test` no longer auto-starts Hologram.** Confirm the suite runs green on ≥ 0.9.2 (the #813 fix is what makes a Hologram-disabled `mix test` not crash). Decide how the few tests that need the running runtime opt in — `HOLOGRAM_START=1` / `mix holo`-style start. **[VERIFY]** exact mechanism.
- **Realtime assertion helper.** v0.9 ships realtime infrastructure (a `SubscriptionRegistry` + feature-test helpers per the changelog). **[VERIFY]** the public API for asserting "action X was broadcast on channel `{:room, id}`" and "instance is subscribed to `{:user, id}`"; if none, assert by subscribing a test process to the channel and matching the delivered action. This helper underpins most new tests below.

### Keep / delete / port (driven by the deletions)
- **Keep unchanged** (domain logic isn't migrating): `scoring_test.exs`, `word_test.exs`, `word_hints_test.exs`, `game_flow_test.exs`, `game_test.exs`, `room_test.exs`, `room_management_test.exs`, `round_timer_test.exs`, and the `integration/` flow tests. `reconnection_handling_test.exs` is **Ash user-state** (score reset on leave, player_state transitions), not WebSocket reconnect — keep it; optionally rename to clarify scope.
- **Delete / rewrite** (assert against handlers being removed): `game_channel_test.exs` (chat_message, get_drawing_path, game-channel presence), `game_channel_drawing_test.exs` (drawing_stroke/_complete/segment/clear/undo), and the channel-broadcast assertions in `integration/drawing_sync_test.exs` / `game_integration_test.exs`. Replace their intent with realtime-broadcast assertions (below) plus the slimmed-channel chunk/terminate tests.
- **Pre-delete check:** confirm nothing asserts on `waiters`/`wait_for_update` before removing that machinery (the suite scan found no dependency — verify with a grep during Phase 2).

### New tests, phase-aligned (the high-value set)
- **Phase 1 (chat):** `action(:chat_appended, %{message})` appends, respects the 50-cap, and **dedupes by message `id`** (no double-apply when the sender's own optimistic append meets the self-echo). Producer test: `RoomServer` send-chat mutation **emits a realtime broadcast** on `{:room, id}` (helper [VERIFY]).
- **Phase 2 (state/timer) — the most important new coverage:**
  - **Version guard (ordering):** feed `action(:room_delta)` out-of-order and duplicate deltas carrying `version` and assert stale ones (`version <= state.version`) are dropped and current state wins. This directly de-risks fire-and-forget delivery.
  - **Word never leaks:** assert the **public** `:room_delta` payload built by `RoomServer.notify_waiters` contains **no raw `current_word`** for non-drawers; the raw word / `word_choices` are broadcast only on the drawer's `{:user, id}` channel. (Security-critical; currently only `is_drawer` masking is tested, not the wire payload.)
  - **Transition port:** move the existing `:room_refreshed` game-start/end/round-change assertions in `game_page_test.exs` onto `action(:room_delta)`; assert a timer-tick delta updates `time_left` with no poll command queued.
  - **Producer:** join/leave/timer mutations emit a `{:room, id}` broadcast (helper [VERIFY]).
- **Phase 3 (drawing):** `action(:stroke_completed | :drawing_cleared | :drawing_undone | :hydrate_canvas)` (port the `:receive_*` assertions from [test/scrawly_web/components/drawing_canvas_test.exs](test/scrawly_web/components/drawing_canvas_test.exs)); `init/3` queues `:hydrate_canvas` with strokes from RoomServer; the completion command uses `put_broadcast_except` so the drawer isn't echoed.
- **Phase 4 (thin channel):** closing the socket (`terminate`) removes the player from `RoomServer` (and the removal emits a delta) **and** broadcasts `drawing_stroke_abandon` for each open stroke; the chunk handler still broadcasts to peers. This is the one genuinely connection-coupled behavior — test it on the slimmed channel.
- **Auth / spectator (cross-cutting):** `init/3` asserts `put_subscription({:room, id})` for members/watchers/anonymous and `{:user, id}` **only** for the drawer; a watcher/anonymous instance never receives a `{:user, id}` payload; watcher action guards block `:canvas_pointer_*` and guess submission.

### Test infrastructure gaps (easy wins, independent of phases)
- **No CI runs the suite** — [.github/workflows/](.github/workflows/) only has `fly-deploy.yml`. Add a workflow that runs `mix test` (Postgres service + the `ash.setup` alias already in [mix.exs](mix.exs), plus the v0.9 test-runner consideration above) on PRs. High value, low effort.
- **No coverage tooling** — optionally add `excoveralls` to spotlight the realtime/auth paths as they land.
- **E2E for the JS canvas (optional, low priority):** there is no Wallaby/Playwright layer, so the SVG drawing round-trip is only covered at the state level. A single multi-browser happy-path E2E (draw → peers see strokes → guess → score) would cover what unit tests structurally can't — defer unless the drawing path regresses.

## Verification (manual, multi-client, per phase)

Two+ browser profiles signed in as different users, same room, DevTools Network open to confirm **SSE frame vs. `poll_room_state` POST**:
- **Phase 1:** A's chat appears on B with no poll POST; system/correct-guess messages appear; drawer can't chat.
- **Phase 2:** start game from host; both transition choosing→drawing; timer ticks on both with no per-tick POST; 3rd client join appears in player list/scoreboard; leave removes; game-end redirects both; hard-close a tab → others see removal shortly.
- **Phase 3:** drawer's completed stroke renders on B and survives a B reload; clear/undo propagate; 3rd client mid-round sees full canvas.
- **Spectator:** logged-out/Watcher session receives chat/state/completed-strokes via SSE, can't draw, can't see the raw word.
- **Reconnect:** drop B's network ~5s, restore → B resyncs full state + canvas, no stuck timer, no missing strokes.
- **Chunks unchanged:** live in-progress strokes still stream ~20Hz; drawer closing mid-stroke clears the peer overlay (not frozen).
- **Regression sweep:** lobby room list live; global "N online" still ticks; home demo board, auth/login/profile/score pages render (v0.9 callback sweep).

## Critical files
- [lib/scrawly_web/pages/game_page.ex](lib/scrawly_web/pages/game_page.ex) — subscription in `init/3`; `:room_delta`/`:chat_appended`/`:stroke_completed`/`:hydrate_canvas` actions
- [lib/scrawly_web/pages/game_page/commands.ex](lib/scrawly_web/pages/game_page/commands.ex) — keep `poll_room_state`/`enrich_state`; new drawing commands with `put_broadcast_except`
- [lib/scrawly/games/room_server.ex](lib/scrawly/games/room_server.ex) — broadcast deltas at `notify_waiters`; broadcast chat at send handler; remove `waiters`
- [lib/scrawly_web/channels/game_channel.ex](lib/scrawly_web/channels/game_channel.ex) — slim to join/chunk/terminate
- [lib/scrawly_web/pages/game_channel.mjs](lib/scrawly_web/pages/game_channel.mjs) + [assets/js/user_socket.js](assets/js/user_socket.js) — strip dispatch glue & dead handlers
- [lib/scrawly_web/channels/presence.ex](lib/scrawly_web/channels/presence.ex) — drop game-channel role, keep lobby `online_count`
- [mix.exs](mix.exs), [config/dev.exs](config/dev.exs), [config/test.exs](config/test.exs), [lib/scrawly_web/endpoint.ex](lib/scrawly_web/endpoint.ex), [lib/scrawly/application.ex](lib/scrawly/application.ex) — v0.9 upgrade wiring
