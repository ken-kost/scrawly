# Phase 1 Fixes Report

> Scrawly — Multiplayer Drawing & Guessing Game
> Date: 2026-04-09

---

## Overview

This report covers 7 tasks addressing critical bugs, architectural debt, and a Phoenix.Presence integration identified during a review of the Phase 1 codebase. All changes pass the full 225-test suite with zero failures.

---

## Task 1: PubSub Module Config

**Status:** Already fixed
**Reported Issue:** `UndefinedFunctionError` on room update actions — `Scrawly.PubSub` in Room resource references process name, not module.

**Finding:** The `Scrawly.PubSub` module (`lib/scrawly/pubsub.ex`) correctly implements `broadcast/3` as expected by `Ash.Notifier.PubSub`. The Phoenix.PubSub process is registered under the same name (`Scrawly.PubSub`) in the supervision tree. Both coexist because Elixir module names and process names are independent. Verified by subscribing to a room topic and triggering an update — the notification was received successfully.

**Files:** No changes needed.

---

## Task 2: Drawer Rotation Bug

**Status:** Already fixed
**Reported Issue:** After a round completes, the next drawer is always `player[0]` because `complete_round` clears `current_drawer_id` before `select_next_drawer` reads it.

**Finding:** The `complete_round` action in `lib/scrawly/games/game.ex:113-120` only clears `current_word`, explicitly preserving `current_drawer_id` with a comment explaining why. The `select_next_drawer` action correctly reads `game.current_drawer_id` from the changeset data and rotates to the next player in the queue. Verified via 60 integration tests passing.

**Files:** No changes needed.

---

## Task 3: Extract GamePage Server Commands

**Status:** Completed
**Problem:** `game_page.ex` was 1,028 lines, mixing Hologram UI logic with server-side command implementations (DB queries, RoomServer calls, word hint computation).

**Solution:** Extracted all 9 server-side `command/3` implementations into a new `ScrawlyWeb.Pages.GamePage.Commands` module. The page module now contains one-liner delegators.

**Changes:**

| File | Action | Lines |
|------|--------|-------|
| `lib/scrawly_web/pages/game_page/commands.ex` | Created | 161 |
| `lib/scrawly_web/pages/game_page.ex` | Reduced | -230 |

**Extracted functions:**
- `poll_room_state/2` — reads RoomServer state, computes per-user fields (word hints, drawer name)
- `join_room/2` — joins player via RoomServer + Ash, notifies channel clients
- `join_as_watcher/2`, `leave_watcher/2` — watcher lifecycle
- `start_game/2` — orchestrates game creation, AI word generation, round start
- `end_game/2`, `leave_room/2` — game/room teardown
- `send_chat_message/2`, `record_correct_guess/2` — chat and scoring

Also removed the unused `close_guess?/2` function.

---

## Task 4: Refactor RoomServer Concerns

**Status:** Completed
**Problem:** `room_server.ex` was 630 lines, mixing GenServer boilerplate with game flow logic, chat helpers, and round result tracking.

**Solution:** Extracted game flow and helper functions into `Scrawly.Games.RoomServer.GameFlow`. The GenServer delegates via thin wrappers.

**Changes:**

| File | Action | Lines |
|------|--------|-------|
| `lib/scrawly/games/room_server/game_flow.ex` | Created | 120 |
| `lib/scrawly/games/room_server.ex` | Reduced | 630 → 555 |

**Extracted functions:**
- `auto_next_round/3` — round advancement (word selection, drawer rotation, timer start)
- `auto_end_game/4` — game completion (result saving, cleanup, self-stop scheduling)
- `capture_round_result/2` — per-round score snapshot
- `get_player_name/2` — player ID → username lookup
- `add_sys_msg/2` — system chat message creation

The GenServer passes `&bump_version/1` and `&notify_waiters/1` as function references to keep state mutation control inside the GenServer while the logic lives in the extracted module.

---

## Task 5: Server-Side Chat Rate Limiting

**Status:** Completed
**Problem:** Chat rate limiting (3 messages per 5 seconds) was enforced only on the client side in Hologram actions. Trivially bypassable via direct WebSocket messages.

**Solution:** Added server-side rate limiting in two layers:

### Layer 1: RoomServer (Hologram command path)
Tracks per-player message timestamps in `chat_rate_limits` map within GenServer state. Returns `{:error, :rate_limited}` when exceeded. System messages (`:system`, `:correct_guess`) always bypass the check.

### Layer 2: GameChannel (WebSocket path)
Tracks per-socket timestamps in `socket.assigns.chat_timestamps`. Returns `{:error, %{reason: "rate_limited"}}` when exceeded.

**Changes:**

| File | Change |
|------|--------|
| `lib/scrawly/games/room_server.ex` | Added `chat_rate_limits` to state, rate check in `handle_call({:send_chat_message, ...})` |
| `lib/scrawly_web/channels/game_channel.ex` | Added rate check in `handle_in("chat_message", ...)` |

**Constants:** `@chat_max_messages 3`, `@chat_window_ms 5_000` (both files).

---

## Task 6: Word Pool Recycling

**Status:** Completed
**Problem:** No fallback when the word pool is depleted mid-game. AI-sourced rooms could run out of generated words with no refill mechanism.

**Solution:** Two improvements:

### Used Word Tracking
Added `used_words` field to RoomServer state. `GameFlow.auto_next_round` passes the accumulated used words to `start_round`, which passes them as the `used_words` argument to `get_random_word`. The DB word selector already falls back to the full pool when all words are excluded (existing behavior), so this prevents repeats as long as the pool has unused words.

### Async AI Word Refill
When an AI-sourced room's `ai_words` pool drops to ≤ 2 words during `auto_next_round`, it sends a `{:refill_ai_words, ...}` message to the GenServer. The handler calls `Games.generate_ai_words` to fetch a new batch and appends them to the existing pool. This runs asynchronously so it doesn't block the current round.

**Changes:**

| File | Change |
|------|--------|
| `lib/scrawly/games/room_server.ex` | Added `used_words` field, `:refill_ai_words` handler, reset on game start |
| `lib/scrawly/games/room_server/game_flow.ex` | Tracks used words, passes to `start_round`, triggers async AI refill |

---

## Task 7: Phoenix.Presence Integration

**Status:** Completed
**Problem:** Phoenix.Presence was tracked on channel join with minimal metadata (`username`, `player_state`, `joined_at`) but not wired up for real-time UI updates. The dual-tracking system (Presence + RoomServer) was not integrated.

**Solution:** Three-part integration:

### Enriched Presence Metadata
`GameChannel.handle_info(:after_join, ...)` now fetches RoomServer state to enrich Presence metadata with `score` and `is_drawer` fields alongside the existing `username` and `player_state`.

### Server-Side Diff Handling
Added `init/1` and `handle_metas/4` callbacks to `ScrawlyWeb.Presence`. When players join or leave (detected via Presence diffs), it broadcasts `room_state_changed` via PubSub to the room topic. This triggers all connected channel clients to immediately poll for fresh state.

### Client-Side Diff Handling
Added `presence_diff` event handler in `game_channel.mjs` that dispatches `poll_room` to Hologram. This ensures the player roster updates immediately when someone joins or disconnects, rather than waiting for the next scheduled poll cycle.

**Changes:**

| File | Change |
|------|--------|
| `lib/scrawly_web/channels/presence.ex` | Added `init/1` and `handle_metas/4` callbacks |
| `lib/scrawly_web/channels/game_channel.ex` | Enriched Presence metadata with `score` and `is_drawer` |
| `lib/scrawly_web/pages/game_channel.mjs` | Added `presence_diff` → `poll_room` handler |

---

## Test Results

```
Running ExUnit with seed: 203314, max_cases: 32

225 tests, 0 failures
Finished in 25.9 seconds
```

All existing tests continue to pass after the changes.

---

## Files Changed Summary

| File | Type |
|------|------|
| `lib/scrawly_web/pages/game_page/commands.ex` | New |
| `lib/scrawly/games/room_server/game_flow.ex` | New |
| `lib/scrawly_web/pages/game_page.ex` | Modified |
| `lib/scrawly/games/room_server.ex` | Modified |
| `lib/scrawly_web/channels/game_channel.ex` | Modified |
| `lib/scrawly_web/channels/presence.ex` | Modified |
| `lib/scrawly_web/pages/game_channel.mjs` | Modified |
