# Scrawly - Technical Project Report

> Multiplayer drawing & guessing game built with Elixir, Ash Framework, Hologram, and Phoenix Channels.
> Report generated: 2026-04-08

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [Timeline & Development Journey](#timeline--development-journey)
- [Architecture Overview](#architecture-overview)
- [Technology Stack](#technology-stack)
- [Codebase Metrics](#codebase-metrics)
- [Domain Model](#domain-model)
- [System Components Deep Dive](#system-components-deep-dive)
- [Real-Time Communication Architecture](#real-time-communication-architecture)
- [Game Flow State Machine](#game-flow-state-machine)
- [Key Algorithms](#key-algorithms)
- [Test Coverage](#test-coverage)
- [Known Issues & Technical Debt](#known-issues--technical-debt)
- [Current Working State (Uncommitted)](#current-working-state-uncommitted)
- [Phase Completion Status](#phase-completion-status)

---

## Executive Summary

Scrawly is a Pictionary-style multiplayer drawing game. Players join rooms, take turns drawing assigned words while others guess in real-time. The project uses an unconventional stack combining **Ash Framework** (declarative domain modeling), **Hologram** (Elixir-to-JavaScript full-stack framework), and **Phoenix Channels** (WebSocket real-time communication).

Phase 1 (MVP) is **100% complete** across all 8 feature areas with 25 test files and 54+ integration tests. Phase 2 and 3 remain untouched.

---

## Timeline & Development Journey

### Commit Activity Heatmap

```
Date         Commits  Activity
──────────── ──────── ────────────────────────────────────────
2025-08-10        2   ██                          Init
2025-08-28       22   ██████████████████████      Sprint 1: Foundation
2025-08-30        8   ████████                    Hologram frontend
2025-09-01        1   █                           Fixes
2025-09-02        5   █████                       LiveView experiment
2025-09-04        9   █████████                   Drawing system
2025-09-06        8   ████████                    Game flow
2025-09-09       10   ██████████                  Auth integration
                      ─── 6 month gap ───
2026-03-13        2   ██                          Enhancements + fixes
                      ─── 26 day gap ───
2026-04-08        -   (uncommitted)               Major expansion
```

### Development Phases (Chronological)

```
Aug 10 ──────── Project Init (Phoenix + Ash scaffold)
    |
Aug 28 ──┬──── PR #1: Backend Infrastructure Setup
    |    |       Ash domains (Games, Accounts), Room/Game/User resources
    |    |       PostgreSQL schema, authentication tokens
    |    |
    |    ├──── PR #2: Room Management System
    |    |       Room CRUD, unique code gen, capacity limits (2-12)
    |    |       Player join/leave, auto-start logic, disconnect handling
    |    |
    |    └──── PR #3: Real-time Communication Infrastructure
    |            Phoenix Channels, GameChannel, Presence tracking
    |            JavaScript WebSocket client (GameSocket class)
    |
Aug 30 ──────── PR #4: Hologram Frontend Foundation
    |            HomePage, GamePage, RoomList, PlayerList, ChatBox
    |            ScoreBoard components, Hologram page architecture
    |
Sep 01-02 ───── (Abandoned) feature/4.5-hologram-to-liveview-migration
    |            Attempted LiveView migration, reverted back to Hologram
    |            Created fix-hologram branch, resolved Hologram issues
    |
Sep 04 ──────── PR #6: Drawing System Implementation
    |            SVG-based DrawingCanvas, pointer events, path generation
    |            Drawing sync via channels, coordinate batching
    |
Sep 06 ──────── PR #7: Basic Game Flow
    |            RoundTimer GenServer, Word resource (~300 words)
    |            Round-based gameplay, drawer rotation, scoring
    |
Sep 09 ──────── PR #8: Auth + Hologram Integration
    |            Magic link authentication, JWT token handling
    |            Username generation, session management
    |
    |           ─── 6 month hiatus ───
    |
Mar 13, 2026 ── Enhancements: removed Phoenix check plug, fixes
    |
Apr 08, 2026 ── (Uncommitted) Massive expansion:
                 RoomServer GenServer, WordHints, GameResult, PubSub module,
                 LobbyChannel, AI word generation, game_channel.mjs,
                 drawing_manager.mjs, lobby_channel.mjs,
                 GameScorePage, PastGamesPage, +942 net lines changed
```

### Key Decision: The Hologram Experiment

A notable detour occurred on Sep 1-2, 2025 when branch `feature/4.5-hologram-to-liveview-migration` attempted to migrate from Hologram to Phoenix LiveView. This branch was **abandoned** (6 commits, never merged). The project recommitted to Hologram with `fix-hologram` branch fixes, landing on the current hybrid architecture where:

- **Hologram** handles page rendering, client-side state, and UI
- **Phoenix Channels** handle real-time drawing/chat (Hologram has no server push)
- **HTTP/2 polling** bridges the gap (500ms polling cycle for state sync)

---

## Architecture Overview

```
                    +-----------------------------------------+
                    |              Browser (Client)            |
                    |                                         |
                    |   Hologram Runtime    Phoenix Socket     |
                    |   (Elixir -> JS)     (WebSocket)        |
                    |        |                   |            |
                    |   [Actions/State]    [Drawing/Chat]     |
                    +--------|-------------------|------------+
                             |                   |
                        HTTP/2 POST         WebSocket
                        (Commands)          (Events)
                             |                   |
                    +--------|-------------------|------------+
                    |        v                   v            |
                    |   Hologram Cmd      GameChannel         |
                    |   Handlers          LobbyChannel        |
                    |        |                   |            |
                    |        +-------+-----------+            |
                    |                |                        |
                    |         RoomServer (GenServer)          |
                    |         [one per active room]           |
                    |                |                        |
                    |     +----------+-----------+            |
                    |     |          |           |            |
                    |  RoundTimer  Ash Domain  PubSub         |
                    |  (singleton)  Layer      (Phoenix)      |
                    |     |          |                        |
                    |     |     +----+-----+                  |
                    |     |     |          |                  |
                    |     |   Games    Accounts               |
                    |     |   Domain   Domain                 |
                    |     |     |          |                  |
                    |     +-----+----+-----+                  |
                    |                |                        |
                    |          PostgreSQL                     |
                    +-----------------------------------------+
```

### Supervision Tree

```
Scrawly.Supervisor (one_for_one)
 |
 +-- ScrawlyWeb.Telemetry
 +-- Scrawly.Repo ........................ Ecto/PostgreSQL
 +-- DNSCluster
 +-- Phoenix.PubSub ...................... Inter-process messaging
 +-- Registry (Scrawly.RoomRegistry) ..... Room process lookup
 +-- DynamicSupervisor ................... Room process lifecycle
 |     +-- RoomServer(room_A) ........... [temporary, per-room]
 |     +-- RoomServer(room_B)
 |     +-- ...
 +-- ScrawlyWeb.Presence ................. Player tracking
 +-- Scrawly.Games.RoundTimer ............ Singleton timer manager
 +-- ScrawlyWeb.Endpoint ................. HTTP + WebSocket server
 +-- AshAuthentication.Supervisor ........ Auth token management
```

---

## Technology Stack

### Core Dependencies

| Package | Version | Role |
|---------|---------|------|
| `phoenix` | ~1.8.0 | Web framework, HTTP server, channels |
| `ash` | ~3.19 | Declarative domain/resource modeling |
| `ash_postgres` | ~2.8 | PostgreSQL data layer for Ash |
| `ash_authentication` | ~4.13 | Magic link auth, JWT tokens |
| `ash_authentication_phoenix` | ~2.15 | Auth UI components |
| `ash_phoenix` | ~2.3 | Ash-Phoenix integration utilities |
| `hologram` | ~0.8 | Full-stack Elixir-to-JS framework |
| `phoenix_live_view` | ~1.1 | LiveView (auth pages only) |
| `langchain` | ~0.3 | LLM integration for AI word gen |

### Dev/Tooling

| Package | Version | Role |
|---------|---------|------|
| `ash_admin` | ~0.14 | Admin UI for Ash resources |
| `ash_ai` | ~0.5 | AI integration for Ash |
| `live_debugger` | ~0.3 | Runtime debugging |
| `tidewave` | ~0.5 | Dev tooling |
| `esbuild` | ~0.10 | JavaScript bundling |
| `tailwind` | ~0.3 | CSS framework (v4.1.7) |

### Runtime

| Component | Version |
|-----------|---------|
| Erlang/OTP | 26.2.2 |
| Elixir | 1.18.4 |
| PostgreSQL | (local, port 5432) |
| Node.js | (for asset compilation) |

---

## Codebase Metrics

### Lines of Code

```
Category              Files    Lines     Largest File
────────────────────  ─────    ──────    ──────────────────────────────
Elixir Source (lib/)    46     6,120     game_page.ex (1,028)
Elixir Tests (test/)    25     4,078     chat_system_test.exs (584)
JavaScript (.mjs)        3       204     drawing_manager.mjs (84)
JavaScript (.js)         6       389     user_socket.js (304)
────────────────────  ─────    ──────
TOTAL                   80    10,791
```

### Top 10 Largest Source Files

| # | File | Lines | Purpose |
|---|------|-------|---------|
| 1 | `game_page.ex` | 1,028 | Main gameplay page (Hologram) |
| 2 | `room_server.ex` | 630 | GenServer per-room state |
| 3 | `home_page.ex` | 485 | Room list & creation (Hologram) |
| 4 | `core_components.ex` | 472 | Phoenix UI components |
| 5 | `room.ex` | 319 | Room Ash resource |
| 6 | `user_socket.js` | 304 | WebSocket client class |
| 7 | `game_channel.ex` | 268 | Channel event handlers |
| 8 | `user.ex` | 194 | User Ash resource + auth |
| 9 | `word.ex` | 189 | Word database + seeding |
| 10 | `round_timer.ex` | 180 | Timer GenServer |

### Git Statistics

| Metric | Value |
|--------|-------|
| Total commits | 63 |
| Merged PRs | 7 |
| Feature branches | 8 (+ 1 abandoned) |
| Contributors | 1 (ken-kost) |
| First commit | 2025-08-10 |
| Latest commit | 2026-03-13 |
| Active dev period | ~30 days (Aug-Sep 2025) |
| Uncommitted changes | 38 files, +2,506 / -1,564 lines |

---

## Domain Model

### Ash Resource Map

```
+------------------+           +-------------------+
|   Scrawly.Games  | (domain)  | Scrawly.Accounts  | (domain)
+------------------+           +-------------------+
|                  |           |                   |
|  +------------+  |           |  +-------------+  |
|  |    Room    |  |           |  |    User     |  |
|  +------------+  |           |  +-------------+  |
|  | id (UUID)  |  |     +------>| id (UUID)   |  |
|  | name       |  |     |    |  | email (uniq)|  |
|  | code (uniq)|  |     |    |  | username    |  |
|  | status     |<--------+   |  | score       |  |
|  | max_players|  |     | |  |  | player_state|  |
|  | creator_id-+--+-----+ |  |  | current_room|  |
|  | current_rnd|  |       |  |  +-------------+  |
|  | word_count |  |       |  |                   |
|  | word_source|  |       |  |  +-------------+  |
|  | prompt     |  |       |  |  |    Token    |  |
|  | ai_tone    |  |       |  |  +-------------+  |
|  | rnd_dur    |  |       |  |  | (JWT mgmt)  |  |
|  | rnd_mult   |  |       |  |  +-------------+  |
|  +------+-----+  |       |  +-------------------+
|         |        |       |
|  +------+-----+  |       |
|  |    Game    |  |       |
|  +------------+  |       |
|  | id (UUID)  |  |       |
|  | room_id    |  |       |
|  | status     |  |       |
|  | current_rnd|  |       |
|  | total_rnds |  |       |
|  | current_wrd|  |       |
|  | drawer_id--+--+-------+
|  | rnd_details|  |       |
|  +------+-----+  |       |
|         |        |       |
|  +------+-----+  |       |
|  | GameResult |  |       |
|  +------------+  |       |
|  | player_id--+--+-------+
|  | game_id    |  |
|  | room_id    |  |
|  | score      |  |
|  | username   |  |
|  +------------+  |
|                  |
|  +------------+  |
|  |    Word    |  |
|  +------------+  |
|  | text (uniq)|  |
|  | difficulty |  |
|  | word_count |  |
|  +------------+  |
+------------------+
```

### Database Schema (PostgreSQL)

```sql
-- Enums
CREATE TYPE room_status AS ENUM ('lobby', 'playing', 'ended');
CREATE TYPE game_status AS ENUM ('in_progress', 'completed', 'cancelled');
CREATE TYPE player_state AS ENUM ('connected', 'drawing', 'guessing', 'disconnected');
CREATE TYPE word_difficulty AS ENUM ('easy', 'medium', 'hard');

-- Tables
rooms (id UUID PK, name, code UNIQUE, status, max_players, creator_id FK,
       current_round, word_count, word_source, prompt, round_duration,
       round_multiplier, ai_tone, timestamps)

users (id UUID PK, email UNIQUE CI, username, score, player_state,
       current_room_id FK, hashed_password, timestamps)

games (id UUID PK, room_id FK, status, current_round, total_rounds,
       current_word, current_drawer_id FK, round_details JSONB, timestamps)

words (id UUID PK, text, difficulty, word_count, timestamps)
       UNIQUE(text, difficulty, word_count)

game_results (id UUID PK, player_id FK, game_id FK, room_id FK,
              score, player_username, timestamps)

tokens (jti PK, subject, expires_at, purpose, extra_data, timestamps)
```

---

## System Components Deep Dive

### RoomServer (GenServer per Room)

The central state machine managing all in-game activity. One process per active room, registered via `Scrawly.RoomRegistry`.

```
RoomServer State Fields:
+───────────────────┬────────────────────────────────────────────+
| Field             | Type / Purpose                             |
+───────────────────┼────────────────────────────────────────────+
| room_id           | UUID - Ash Room resource ID                |
| name              | String - Room display name                 |
| code              | String - Unique join code                  |
| status            | :lobby | :playing | :ended                 |
| creator_id        | UUID - Room creator                        |
| players           | [%{id, username, score, ...}]              |
| version           | Integer - Incremented on every state change|
+───────────────────┼────────────────────────────────────────────+
| game_id           | UUID - Active Ash Game resource             |
| current_round     | Integer                                    |
| total_rounds      | Integer (players * multiplier)             |
| current_drawer_id | UUID                                       |
| current_word      | String (the secret word)                   |
| time_left         | Integer (seconds remaining)                |
| round_active      | Boolean                                    |
| correct_guessers  | [UUID] - Players who guessed correctly     |
+───────────────────┼────────────────────────────────────────────+
| chat_messages     | [%{player_name, message, type, timestamp}] |
| drawing_path      | String (accumulated SVG path data)         |
| ai_words          | [String] - Pre-generated AI words          |
| watchers          | [%{...}] - Non-playing viewers             |
| last_game_id      | UUID - For redirect to results             |
+───────────────────┴────────────────────────────────────────────+
```

### RoundTimer (Singleton GenServer)

Manages countdown timers for all active games simultaneously.

```
RoundTimer State:
  timers: %{
    game_id_1 => {timer_ref, start_time, duration_ms, remaining_ms},
    game_id_2 => {timer_ref, start_time, duration_ms, remaining_ms},
    ...
  }

Behavior:
  start_timer(game_id, duration_ms)
    -> Stores timer, sends :tick every 1 second
    -> Broadcasts {:timer_update, time_left} via PubSub
    -> On expiry: broadcasts {:round_ended, reason: :time_up}

  stop_timer(game_id)
    -> Cancels timer, removes from state
```

### Hologram Page Lifecycle

```
                     Client (Browser)                    Server (BEAM)
                     ────────────────                    ──────────────

   Navigate to /game/:room_id
        |
        +------ HTTP GET ---------------------------------->  init/3
        |                                                     |
        |                                              Read session,
        |                                              load Room/User,
        |                                              return initial state
        |                                                     |
        <------ HTML + compiled JS ---------------------------|
        |
   Hologram Runtime boots
   Renders template from state
        |
   action(:poll_room, delay: 500)  ----+
        |                               |
        |   [500ms]                     |
        |                               |
   action(:poll_room)                   |
        |                               |
   put_command(:poll_room_state) -------+----> command/5
        |                               |        |
        |                               |   RoomServer.get_state()
        |                               |   Compute word_display
        |                               |   Return state map
        |                               |        |
   <--- HTTP Response (state) ---------/---------|
        |
   action(:room_refreshed, state)
        |
   put_state(new values)
        |
   Template re-renders
        |
   action(:poll_room, delay: 500)  ---- [cycle repeats]
```

---

## Real-Time Communication Architecture

### Channel Topology

```
Browser A ──── WebSocket ──┐
                           |
Browser B ──── WebSocket ──┼──── UserSocket ──┬── GameChannel("game:ABCDEF")
                           |                  |
Browser C ──── WebSocket ──┘                  └── LobbyChannel("lobby:rooms")
```

### Event Flow Matrix

| Event | Direction | Channel | Payload |
|-------|-----------|---------|---------|
| `drawing_segment` | Client -> Server -> Clients | GameChannel | `{path_segment: "L 120 340 ..."}` |
| `drawing_clear` | Client -> Server -> Clients | GameChannel | `{}` |
| `chat_message` | Client -> Server -> Clients | GameChannel | `{player_name, message, type}` |
| `correct_guess` | Client -> Server -> Clients | GameChannel | `{player_name, points}` |
| `get_drawing_path` | Client -> Server -> Client | GameChannel | Reply: `{path: "M 0 0 L ..."}` |
| `rooms_updated` | Server -> Clients | LobbyChannel | `{rooms: [...]}` |

### Authentication Flow

```
1. User enters email at /register
      |
2. request_magic_link ─── Ash Action ──── Swoosh Email ───> inbox
      |
3. User clicks link: /magic_link/:token
      |
4. sign_in_with_magic_link ─── validate token ──── create/find User
      |                                              |
5. JWT generated ──── stored in session ─────────── cookie
      |
6. WebSocket connect: params[:token] ──── AshAuthentication.Jwt.verify
      |
7. GameChannel join: socket.assigns.user_id verified
```

---

## Game Flow State Machine

### Room Lifecycle

```
            create_room
                |
                v
          +───────────+     join_room (2+ players)     +───────────+
          |   LOBBY   | ────────────────────────────>  |  PLAYING  |
          +───────────+     start_game (creator)       +───────────+
                ^                                           |
                |              end_game /                   |
                |              all rounds complete          |
                |                                           v
                |                                     +───────────+
                +─────────── (new game in same room)  |   ENDED   |
                                                      +───────────+
                                                           |
                                                           v
                                                    GameScorePage
                                                    (results view)
```

### Round Lifecycle

```
  start_round
      |
      v
  Select word ──> Select drawer ──> Start timer (80s default)
      |
      v
  +-----------+
  | ROUND     |     drawer draws ──> segments broadcast to viewers
  | ACTIVE    |     guesser types ──> chat_message parsed
  |           |         |
  |           |    correct guess? ──> +10 guesser, +5 drawer
  |           |         |              add to correct_guessers
  |           |         |
  |           |    all guessed? ──> stop timer, auto-advance (3s)
  +-----------+         |
      |            time expires ──> :round_ended broadcast
      v
  complete_round
      |
      +──── round < total_rounds? ──> next_round() ──> [start_round]
      |
      +──── round == total_rounds? ──> end_game()
                                          |
                                     save GameResults
                                     set last_game_id
                                     redirect to scores
```

### Scoring Model

```
Event                        Points    Condition
──────────────────────────── ──────── ────────────────────────────
Correct guess (guesser)       +10     Per correct guess
Successful round (drawer)     +5      At least 1 correct guess
Failed round (drawer)         -5      Nobody guessed
No guess (guesser)             0      Round expired without guess

Future (Phase 2):
Speed bonus (guesser)       50-500    base(50) + (time_left * 450 / 80)
Drawer bonus                  +50     Per correct guesser (when all guess)
```

---

## Key Algorithms

### Word Hint Generation (`WordHints`)

Progressive reveal based on time remaining as a proportion of round duration:

```
Time Remaining (%)    Display                 Example ("butterfly")
──────────────────    ──────────────────────   ─────────────────────
75% - 100%            All underscores          _ _ _ _ _ _ _ _ _
50% - 75%             First letter             b _ _ _ _ _ _ _ _
25% - 50%             First + last             b _ _ _ _ _ _ _ y
0%  - 25%             First + last + middle    b _ _ _ e _ _ _ y

Multi-word: spaces shown as " / "             _ _ _ / _ _ _ _ _
Middle letter: deterministic via :erlang.phash2(word)
```

### Close Guess Detection (Levenshtein Distance)

```elixir
# A guess is "close" if ANY of these are true:
1. guess contains word as substring          "the butterfly" matches "butterfly"
2. word contains guess as substring          "butter" matches "butterfly" (len >= 3)
3. same length, Levenshtein distance <= 2    "butterly" matches "butterfly"
4. off-by-one length, Levenshtein <= 2       "butterfl" matches "butterfly"
```

### Room Code Generation

```elixir
:crypto.strong_rand_bytes(4) |> Base.encode32(padding: false) |> binary_part(0, 6)
# Produces: "ABCDEF" style 6-char uppercase codes
# Collision: checked via unique database constraint
```

### AI Word Generation (LangChain + GPT-4o-mini)

```
Input: {num_words, word_count, prompt, tone}
       e.g., {10, 2, "animals in space", "funny"}

Prompt -> LangChain.ChatOpenAI -> Parse JSON array -> Store in RoomServer.ai_words
Words consumed one-per-round, refill when exhausted.
```

---

## Test Coverage

### Test Suite Summary

```
Category                        Files  Purpose
────────────────────────────── ───── ─────────────────────────────────
Unit: Domain Resources            7  Room, Game, Word, User, RoundTimer
Unit: Web Components              3  DrawingCanvas, ChatSystem, GamePage
Unit: Channels                    2  GameChannel events, drawing events
Unit: Pages                       3  HomePage, HomePageAuth, GamePage
Integration: Game Flow            1  Full lifecycle (room -> game -> end)
Integration: Multiplayer          1  4 concurrent players, rotation
Integration: Drawing Sync         1  Real-time SVG broadcast
Integration: Reconnection         1  Disconnect/reconnect during game
Integration: Scoring              1  Score persistence, leaderboard sort
Integration: Capacity             1  Max 12 players, capacity enforcement
────────────────────────────────────
Total                            25  ~4,078 lines of test code
```

### Test Files by Size

| File | Lines | Focus |
|------|-------|-------|
| `chat_system_test.exs` | 584 | Message types, rate limiting, close guesses |
| `score_leaderboard_test.exs` | 289 | Scoring formula, persistence, sorting |
| `complete_game_flow_test.exs` | 290 | End-to-end game lifecycle |
| `multiplayer_simultaneous_test.exs` | 270 | Concurrent players, turn rotation |
| `reconnection_handling_test.exs` | 262 | Disconnect/reconnect scenarios |
| `game_page_test.exs` | 244 | Hologram page state management |
| `max_capacity_test.exs` | 240 | Room limits, capacity enforcement |
| `drawing_sync_test.exs` | 179 | SVG path broadcast, multi-stroke |
| `room_management_test.exs` | 163 | Room CRUD, player join/leave |
| `guessing_test.exs` | 160 | Guess validation, close match detection |

### Test Coverage by Feature

```
Feature                      Tests  Status
──────────────────────────── ────── ──────
Backend Infrastructure         4+   PASS
Room Management               10+   PASS
Real-time Communication        9    PASS
Hologram Frontend              8+   PASS
Drawing System                10+   PASS
Game Flow                      7+   PASS
Word & Guessing System        46+   PASS
Chat System                   41+   PASS
Phase 1 Integration           54    PASS (2 known bugs documented)
```

---

## Known Issues & Technical Debt

### Critical Bugs (Documented in `phase-1-integration-tests.md`)

| # | Issue | Impact | Root Cause |
|---|-------|--------|------------|
| 1 | **PubSub module config** | `UndefinedFunctionError` on room update actions | `module Scrawly.PubSub` in Room resource references process name, not module |
| 2 | **Drawer rotation breaks** | Always selects player[0] after round | `complete_round` clears `current_drawer_id` to nil before `select_next_drawer` reads it |

### Architectural Debt

| Area | Issue | Recommendation |
|------|-------|----------------|
| Polling | 500ms HTTP polling (Hologram limitation) | Hologram lacks server push; consider Phoenix Channels for state sync |
| `game_page.ex` | 1,028 lines, handles all game state | Extract state management into dedicated module |
| `room_server.ex` | 630 lines, mixes concerns | Separate game logic, chat, drawing into sub-modules |
| Rate limiting | Client-side only (3 msg / 5 sec) | Move to server-side for production security |
| Word exhaustion | No fallback when word pool depleted | Add recycling or dynamic generation |
| Drawing persistence | Ephemeral (in-memory only) | Consider optional persistence for replay feature |

### Abandoned Branch

`feature/4.5-hologram-to-liveview-migration` (6 commits, Sep 1-2, 2025) attempted migrating from Hologram to LiveView. Never merged. Indicates early uncertainty about Hologram's viability for real-time features. The team resolved this by keeping Hologram for UI rendering and using Phoenix Channels as a parallel real-time layer.

---

## Current Working State (Uncommitted)

As of 2026-04-08, there are **38 modified files** and **30+ new files** uncommitted on `master`, representing a significant expansion since the last commit (2026-03-13).

### New Modules Added (Uncommitted)

| File | Purpose |
|------|---------|
| `room_server.ex` | GenServer managing per-room state (630 lines) |
| `word_hints.ex` | Progressive hint generation algorithm (136 lines) |
| `game_result.ex` | Per-player game result tracking |
| `pubsub.ex` | PubSub wrapper module |
| `lobby_channel.ex` | Room list real-time updates |
| `game_channel.mjs` | JS bridge for game channel |
| `drawing_manager.mjs` | Client-side SVG state management |
| `lobby_channel.mjs` | JS bridge for lobby updates |
| `game_score_page.ex` | Game results display page |
| `past_games_page.ex` | Player game history page |
| `CLAUDE.md` | AI assistant project instructions |
| `current-architecture.md` | Architecture documentation |
| `.claude/skills/ash-framework/` | Ash framework reference (19 files) |

### Major Modifications (Uncommitted)

```
File                          +Ins  -Del  Net   Change Description
──────────────────────────── ───── ───── ───── ──────────────────────────
game_page.ex                 +1203  -369  +834  Complete rewrite w/ RoomServer
home_page.ex                  +367  -118  +249  Room creation form, AI words
word.ex                       +262  -189  +73   Expanded word list, word_count
room.ex                       +146  -173  -27   AI word gen, settings attrs
games.ex (domain)             +91   -53   +38   New code interfaces
score_board.ex                +68   -49   +19   Timer, winner display
chat_box.ex                   +107  -89   +18   Message types, system msgs
game_channel.ex               +56   -39   +17   Drawing events, sync
user_socket.js                +35    0    +35   JWT auth, event callbacks
app_layout.ex                 +48    0    +48   New layout with auth
```

---

## Phase Completion Status

### Phase 1: MVP Core Game Foundation

```
Feature                             Status    PR    Date
─────────────────────────────────── ──────── ───── ──────────
1. Backend Infrastructure Setup      DONE     #1   2025-08-28
2. Room Management System            DONE     #2   2025-08-28
3. Real-time Communication           DONE     #3   2025-08-28
4. Frontend Foundation (Hologram)    DONE     #4   2025-08-30
5. Drawing System Implementation     DONE     #6   2025-09-04
6. Basic Game Flow                   DONE     #7   2025-09-06
6.5 Auth + Hologram Integration      DONE     #8   2025-09-09
7. Word and Guessing System          DONE     (uncommitted)
8. Chat System                       DONE     (uncommitted)
   Phase 1 Integration Tests         DONE     (uncommitted)
─────────────────────────────────── ──────── ───── ──────────
                                    10/10    100%
```

### Phase 2: Enhanced Features (In Progress)

```
Feature                             Status
─────────────────────────────────── ────────
9.  Private Room System              TODO
10. Custom Word Management           TODO
11. Avatar System                    TODO
12. Advanced Drawing Tools           TODO
13. Progressive Hint System          DONE (5-stage hints, vowel priority, configurable schedule, hint_info metadata)
14. Enhanced Scoring System          DONE (50-500 speed curve, hint penalty, drawer per-guesser rewards, server-side calc)
```

### Phase 3: Polish and Optimization (Not Started)

```
Feature                             Status
─────────────────────────────────── ────────
15. Internationalization             TODO
16. Advanced Room Configuration      TODO
17. Voting and Feedback System       TODO
18. Mobile Optimization              TODO
19. Performance Optimization         TODO
20. Analytics and Monitoring         TODO
21. Social Features                  TODO
```

### Overall Progress

```
Phase 1 ████████████████████ 100%  (10/10 features)
Phase 2 ██████░░░░░░░░░░░░░░  33%  (2/6 features)
Phase 3 ░░░░░░░░░░░░░░░░░░░░   0%  (0/7 features)
─────── ───────────────────────────
Total   ██████░░░░░░░░░░░░░░  52%  (12/23 features)
```

---

## Page Routes

| Route | Page Module | Auth Required | Description |
|-------|-------------|---------------|-------------|
| `/` | `HomePage` | No | Room list, create/join |
| `/game/:room_id` | `GamePage` | No (guest=watcher) | Main gameplay |
| `/game-results/:game_id` | `GameScorePage` | No | Final standings |
| `/past-games` | `PastGamesPage` | Yes | Player history |
| `/sign-in` | AshAuthentication LV | No | Magic link auth |
| `/sign-out` | AuthController | Yes | Destroy session |

---

## Summary

Scrawly is a well-structured multiplayer game with a complete MVP. The unconventional Hologram + Phoenix Channels hybrid architecture was arrived at through experimentation (the abandoned LiveView migration branch is evidence of this). The Ash Framework provides a clean declarative domain model, while the GenServer-based `RoomServer` and `RoundTimer` handle the real-time game state that Hologram's HTTP-only model cannot.

The project sat dormant for 6 months (Sep 2025 - Mar 2026) and has recently resumed with a large uncommitted batch of work that completes the remaining Phase 1 features (word system, chat system, integration tests) and adds substantial new infrastructure (RoomServer, AI word generation, game results pages).

The primary technical risks going forward are the polling overhead (500ms per client), the growing size of `game_page.ex` and `room_server.ex`, and the need to resolve the two documented bugs before Phase 2 work begins.
