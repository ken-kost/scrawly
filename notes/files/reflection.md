# Reflection: Architecture Analysis, Issues, and Future Steps

## What Went Well

### 1. RoomServer as Single Source of Truth
The GenServer-per-room pattern proved to be the right abstraction. It cleanly centralizes all room and game state, eliminates DB polling, and provides a natural place for business logic (auto-advance, all-guessed detection, score reset). The pattern is simple to reason about: mutations bump a version, polls read the latest state.

### 2. Ash Framework for Persistence
Ash handled the data modeling and DB persistence cleanly. The declarative resource definitions, code interfaces, and built-in validations (room capacity, lobby state checks) kept the Elixir code concise. The `create_room`, `join_room`, `start_round` actions encapsulate business rules without scattered validation logic.

### 3. Incremental Development
Each phase built on the previous one without requiring rewrites. The RoomServer was added alongside existing DB operations (Ash for persistence, GenServer for real-time). Game state fields were added to the existing struct. Chat and drawing were bolted on to the same polling mechanism.

---

## Key Issues Encountered

### Issue 1: `$show` Does Not Exist in Hologram
**Impact:** All conditional visibility was broken. Buttons, game areas, timer display -- everything was always visible regardless of state.

**Lesson:** Hologram's template system is NOT Vue.js or LiveView. Only documented directives work: `{%if}`, `{%for}`, `$click`, `$submit`, `$input`, `$pointer_*`, etc. When using a lesser-known framework, verify every API against the actual documentation rather than assuming familiar patterns.

### Issue 2: Hologram Client-Side Limitations
**Impact:** Game start, timer updates, and drawing sync all broke silently because `WordHints.generate_hint()` uses `:erlang.phash2` which cannot be compiled to JavaScript.

**Lesson:** This was the hardest bug to diagnose because Hologram actions fail silently in the browser -- no error visible in server logs. The rule is: **any function called in a Hologram action must be compilable to JavaScript**. This means no Erlang BIFs, no complex stdlib functions, no DB calls, no GenServer calls. Only basic Elixir operations.

**Pattern established:** All complex computation goes in server commands. Client actions only do `put_state` with pre-computed values.

### Issue 3: Blocking GenServer.call in Hologram Commands
**Impact:** The initial "long-poll" design (`wait_for_update` blocking for 8 seconds) never worked. The blocking command prevented the Hologram action chain from continuing.

**Lesson:** Hologram commands should be fast and non-blocking. The framework expects a quick HTTP request/response cycle. Long-lived connections or blocking calls break the action->command->action chain. The working pattern is: quick `GenServer.call` read, return immediately, reschedule poll with delay.

### Issue 4: `put_command` from Command-Triggered Actions
**Impact:** Even after switching to non-blocking reads, re-subscribing via `put_command` directly from a command-response action didn't reliably fire.

**Lesson:** In Hologram, when an action is triggered by a command response, chaining `put_command` from that same action doesn't work reliably. The fix was to use `put_action(:poll_room, delay: 500)` (which creates a new action cycle) instead of direct `put_command`. This matches the home page's proven pattern.

### Issue 5: `$keyup`/`$keydown` Not Supported
**Impact:** Enter key didn't send chat messages.

**Lesson:** Only events listed in Hologram's event documentation actually work. `$keyup` and `$keydown` are not in the list. The solution was HTML-native: `<form $submit>` which handles Enter key via standard form submission behavior.

### Issue 6: `DateTime.utc_now()` and `:rand.uniform()` on Client
**Impact:** Chat messages with timestamps and random IDs created on the client caused silent failures.

**Lesson:** Even standard Elixir functions like `DateTime.utc_now()` may not be available in Hologram's browser runtime. All such calls must be in server commands.

---

## Architectural Concerns

### 1. Polling at 500ms is Not True Real-Time
The 500ms polling interval means there's up to half a second of latency for all state changes. For drawing, this creates visible lag between the drawer's strokes and the viewer's rendering. For a production game, this is suboptimal.

**Better approach:** Hologram's HTTP/2 persistent connection could theoretically support server-sent events, but the framework doesn't expose this. A WebSocket channel (like Phoenix Channels) would provide true push. However, Hologram doesn't integrate with Phoenix Channels for page state updates -- it has its own transport.

**Potential improvement:** Reduce poll interval to 200ms during active games (drawing), increase to 2000ms during lobby. Or investigate if Hologram supports any form of server push that wasn't documented in the usage rules.

### 2. Drawing Path Grows Unbounded During a Round
The SVG path string grows with every stroke segment. Over an 80-second round with continuous drawing, it could reach tens of kilobytes. Every poll response includes the full path for the viewer.

**Better approach:**
- Use a path ID + incremental segments system (viewer tracks what it has, server sends only new segments)
- Or periodically "snapshot" the drawing as a rasterized image
- Or limit path complexity (simplify curves, reduce point density)

### 3. RoomServer State is Ephemeral
If the server restarts, all RoomServer state is lost. The GenServer reloads from DB, but in-game state (current round, drawing, chat) is gone. Players would need to restart the game.

**Better approach:**
- Periodic state snapshots to an ETS table or Redis
- Or accept the trade-off for a casual game (game sessions are short)
- The DB has the persistent data (rooms, games, results); only in-flight game state is lost

### 4. No Multi-Node Support
The Registry and DynamicSupervisor are node-local. In a multi-node deployment, players on different nodes can't share a RoomServer.

**Better approach:**
- Use `Horde` (distributed supervisor + registry) for multi-node GenServer distribution
- Or use Phoenix PubSub (which supports multi-node via Redis adapter) for state broadcast
- Or run as single-node with sticky sessions (simplest for the game's scale)

### 5. Security: Word Visible in Client State
The actual word (`current_word`) is in the browser's component state for guess checking. A technically savvy player could inspect the Hologram runtime state to see the word.

**Better approach:**
- Move guess checking entirely to the server: client sends message to server command, server checks against word, returns result
- The client never sees the actual word, only the masked display
- Trade-off: adds latency to guess checking (HTTP round-trip)

### 6. No Drawing Synchronization from Multiple Drawers
Currently only one player can draw (the designated drawer). The viewer sees the drawing but can't contribute. This is correct for the game mechanics, but the drawing canvas component could be extended for collaborative drawing modes.

---

## Recommended Future Steps

### Short-Term (Quality of Life)

1. **Drawing color/size picker** -- Let the drawer choose stroke color and width. Store color metadata alongside path segments.

2. **Word choice** -- Instead of auto-selecting a random word, present the drawer with 3 word options to choose from. This adds strategy and avoids words the drawer can't illustrate.

3. **Sound effects** -- Play a sound on correct guess, round end, game end. Use Hologram's JS interop (`JS.exec`) for audio playback.

4. **Animated transitions** -- Smooth transitions between lobby, game, and score pages instead of instant swaps.

5. **Mobile responsiveness** -- The current layout uses `lg:grid-cols-4` which collapses on mobile, but the drawing canvas and chat need better mobile touch handling.

### Medium-Term (Features)

6. **Spectator mode** -- Watchers can observe the game without participating. The infrastructure exists (Watcher user ID) but the game view doesn't differentiate.

7. **More than 2 players** -- The round rotation logic already supports N players via the modular drawer selection. Test with 3-6 players, ensure scoring and round rotation work correctly.

8. **Custom word lists** -- Let the room creator upload or select themed word packs (animals, movies, food, etc.).

9. **Player avatars** -- Simple generated avatars or emoji selections to distinguish players visually.

10. **Game replay** -- Store drawing path snapshots per round in GameResult. Allow viewing past game drawings on the score page.

### Long-Term (Architecture)

11. **WebSocket drawing channel** -- Replace the 500ms polling for drawing with a dedicated Phoenix Channel. The Hologram page can still poll for game state, but drawing strokes get pushed immediately via WebSocket. This is the single biggest UX improvement possible.

12. **Server-side guess checking** -- Move `guess_matches?` to a server command to prevent word exposure in client state. Accept the latency trade-off (50-100ms is imperceptible to users).

13. **Distributed deployment** -- Replace node-local Registry/DynamicSupervisor with Horde for multi-node support. Add Redis adapter to Phoenix PubSub.

14. **Rate limiting drawing** -- Limit the frequency of `append_drawing` calls to prevent abuse. The 50-char threshold helps but a malicious client could send rapidly.

15. **Comprehensive test suite for RoomServer** -- Unit tests for all GenServer handlers: join, leave, start_game, record_guess, auto_advance, end_game. Integration tests for the full game lifecycle through the GenServer.

---

## Summary

The architecture works well for a 2-player casual game. The RoomServer pattern provides a clean separation between real-time state (GenServer) and persistent data (Ash/PostgreSQL). The main challenges were all related to Hologram's constraints -- a framework that compiles Elixir to JavaScript has inherent limitations on what can run client-side. The key insight: **treat Hologram actions as a thin rendering layer that only does `put_state`, and put all logic in server commands**. This pattern scales and avoids the silent failures that plagued earlier iterations.
