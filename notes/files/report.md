# Scrawly Development Report

## Overview

This report documents the implementation of a real-time multiplayer drawing and guessing game built with Elixir, using Hologram (full-stack framework compiling Elixir to JavaScript), Ash Framework (declarative resource modeling), and a custom GenServer-based real-time architecture.

---

## Phase 1: Room Creator System & Access Control

### Requirements
- Players cannot join a room unless the creator is present
- If the creator leaves, the room vanishes
- Only the creator can start the game
- Creator needs at least one other player to start
- Show real player count on the home page

### Implementation

**Room Resource Changes (`room.ex`)**
- Added `creator_id` attribute (UUID, non-null) with `belongs_to :creator` relationship
- `create` action accepts `creator_id`
- `join_room` validates creator is present (creator themselves bypass this check)
- `handle_player_disconnect` sets room to `:ended` when creator leaves

**Games Domain (`games.ex`)**
- Added `dissolve_room/1` function that kicks all players and marks room as ended

**Home Page (`home_page.ex`)**
- Room list polls every 5 seconds, filters to `:lobby` status only
- Creator flow: authenticated users create room, auto-join, navigate to game page
- Unauthenticated flow: combined email + room name modal

**Game Page (`game_page.ex`)**
- Tracks `is_creator` state
- Start Game button only visible to creator
- Creator leaving dissolves room, other players redirected home

**Migration**
- Added `creator_id` column with FK reference to `users` table

---

## Phase 2: Fixing Hologram Template Rendering

### Discovery
`$show` is **not a Hologram directive** -- it doesn't exist in Hologram's event system. Elements with `$show={false}` were still fully visible in the DOM.

### Fix
Replaced all `$show` usage across 4 files with proper Hologram `{%if}` conditionals:
- `game_page.ex` -- Header buttons, lobby/game areas, word display, drawer info
- `score_board.ex` -- Round info, word display, player list, game winner
- `chat_box.ex` -- Empty messages state, rate limit warning
- `drawing_canvas.ex` -- Clear button visibility

---

## Phase 3: RoomServer GenServer (Eliminating DB Polling)

### Problem
The game page was polling the database every 2-3 seconds with constant SQL queries for room state.

### Solution: RoomServer GenServer
Created a per-room GenServer (`room_server.ex`) that holds all room and game state in memory.

**Architecture:**
- `Registry` (`Scrawly.RoomRegistry`) for looking up RoomServers by room_id
- `DynamicSupervisor` (`Scrawly.RoomSupervisor`) for starting RoomServers on demand
- `ensure_started/1` creates or finds existing RoomServer
- State loaded from DB on init, persisted via Ash actions as secondary

**Initial approach (blocking long-poll):**
- `wait_for_update/3` blocked via `GenServer.call` until state version changed
- Failed because Hologram commands that block don't reliably chain

**Final approach (non-blocking polling):**
- Adopted the same pattern as the working home page:
  ```
  init -> put_action(:poll_room, delay: 500)
  action(:poll_room) -> put_command(:poll_room_state)
  command(:poll_room_state) -> RoomServer.get_state() -> put_action(server, :room_refreshed, state)
  action(:room_refreshed) -> put_state(...) + put_action(:poll_room, delay: 500)
  ```
- 500ms polling interval with in-memory GenServer reads (microseconds, no DB queries)

---

## Phase 4: Full Game Flow via RoomServer

### Problem
Game state (game_id, word, drawer, timer) only reached the creator. The other player's poll only received room-level fields.

### Solution: RoomServer as Single Source of Truth
Extended RoomServer with full game state:
- `game_id`, `current_round`, `total_rounds`, `current_drawer_id`, `current_word`
- `time_left`, `round_active`, `correct_guessers`

**Timer Integration:**
- RoomServer subscribes to RoundTimer PubSub (`"game:#{game_id}"`)
- `handle_info` for `:timer_update`, `:timer_started`, `:round_ended`
- RoundTimer broadcasts every second (changed from every 10s)

**Auto Round Advancement:**
- On `:round_ended` (time up): adds "Time's up!" message, schedules `auto_advance_round` after 3 seconds
- `auto_next_round/1`: Ash operations + update RoomServer state
- `auto_end_game/1`: Final round complete, Ash cleanup, status back to lobby
- Same auto-advance for "all guessed" condition

**Commands push to RoomServer, not `put_action`:**
- `start_game`, `next_round`, `end_game` commands call RoomServer mutations
- Return bare `server` -- both players get state via their polling cycle

---

## Phase 5: Critical Hologram Discovery -- Server-Only Functions

### Problem
Game start, drawing, and timer updates worked on refresh but not in real-time. Player joins (simple `put_state`) worked fine.

### Root Cause
`WordHints.hidden_display()` and `WordHints.generate_hint()` use `:erlang.phash2` and `String.graphemes` -- functions that **Hologram cannot compile to JavaScript**. These were called in client-side actions, causing silent crashes that broke the polling loop.

### Fix
Moved all `WordHints` computation to the server-side `poll_room_state` command. The command pre-computes `is_drawer`, `current_word_display`, and `drawer_name` per-user. Client actions now only do simple `put_state` calls -- identical to the home page pattern.

**Rule established:** Client-side actions must ONLY use Hologram-safe operations (basic Elixir: `put_state`, map operations, simple comparisons). Any complex computation goes in server commands.

---

## Phase 6: Shared Chat & Drawing

### Shared Chat
- `chat_messages` stored in RoomServer state
- Regular messages: client sends via `command(:send_chat_message)` -> RoomServer stores + bumps version -> all players see via poll
- Correct guesses: `command(:record_correct_guess)` persists score to DB, updates RoomServer score + chat + guessers
- System messages (join, leave, game start, round start, time's up): generated server-side in RoomServer handlers
- `DateTime.utc_now()` and `:rand.uniform()` moved to server commands (not Hologram-safe on client)

### Shared Drawing
- Drawing path accumulated locally by drawer for smooth rendering
- Every 50 chars of accumulated unsent path data, auto-sends delta via `command(:send_drawing)`
- On `pointer_up`, flush remaining delta
- RoomServer stores `drawing_path`, bumps version
- Viewer gets `drawing_path` from `room_refreshed` via `sync_drawing_path`
- Canvas cleared on each new round

### Role Enforcement
- Drawer's chat input disabled (`disabled={@is_drawer or !@game_started}`)
- Only drawer can draw (`canvas_pointer_down` checks `is_drawer`)
- `DrawingCanvas` simplified to pure stateless renderer (path as prop, events bubble to page)

---

## Phase 7: Enter Key, Per-Game Scoring, Game Results, Navigation

### Enter Key Fix
- `$keyup` is not a supported Hologram event
- Wrapped chat input in `<form $submit="send_message">` -- HTML forms natively fire submit on Enter
- Removed `$keyup` handler entirely

### Per-Game Score Reset
- `handle_call({:start_game, ...})` in RoomServer now resets all player scores to 0

### GameResult Persistence
- New `Scrawly.Games.GameResult` Ash resource with `player_id`, `game_id`, `room_id`, `score`, `player_username`
- Results saved in both `auto_end_game` and manual `end_game` before clearing state
- `last_game_id` tracked in RoomServer for redirect after game end

### Auth-Aware Header
- `AppLayout` now has `init/3` reading session for auth state
- Logged in: username, "Past Games" link, Logout button
- Guest: Login and Register links

### Game Score Page (`/game-results/:game_id`)
- Ranked player scores with current user highlighted
- "Back to Lobby" and "Play Again" buttons

### Redirect on Game End
- `room_refreshed` detects `old_started and not new_game_active` with `last_game_id`
- Both players redirected to score page via `put_page`

### Past Games Page (`/past-games`)
- Lists all past game results for logged-in user, sorted by date
- Clickable to view full game scores

---

## Test Results

All changes maintained passing tests throughout development:
- **218 tests, 0 failures** at final state
- Tests updated to reflect architectural changes (RoomServer polling, server-side message creation, form-based chat submit, score page redirect)

---

## Files Created

| File | Purpose |
|------|---------|
| `lib/scrawly/games/room_server.ex` | Per-room GenServer: single source of truth |
| `lib/scrawly/games/game_result.ex` | Ash resource for persistent game results |
| `lib/scrawly_web/pages/game_score_page.ex` | Game results display page |
| `lib/scrawly_web/pages/past_games_page.ex` | Player's game history page |

## Files Significantly Modified

| File | Changes |
|------|---------|
| `lib/scrawly/games/room.ex` | creator_id, join validation, disconnect handling |
| `lib/scrawly/games.ex` | dissolve_room, save_game_results, GameResult interfaces |
| `lib/scrawly_web/pages/game_page.ex` | Complete rewrite: RoomServer polling, shared state, drawing |
| `lib/scrawly_web/pages/home_page.ex` | Creator flow, room polling, auth gating |
| `lib/scrawly_web/components/drawing_canvas.ex` | Simplified to pure renderer |
| `lib/scrawly_web/components/chat_box.ex` | Form-based submit, removed $keyup |
| `lib/scrawly_web/components/score_board.ex` | Replaced $show with {%if} |
| `lib/scrawly_web/layouts/app_layout.ex` | Auth-aware header navigation |
| `lib/scrawly/application.ex` | Registry + DynamicSupervisor for RoomServer |
| `lib/scrawly/games/round_timer.ex` | Broadcast every second |
