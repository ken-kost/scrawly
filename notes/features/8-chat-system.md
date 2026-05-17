# Feature: Chat System

## Summary
Complete chat system with event-driven messaging, rate limiting, close-guess detection, system messages for all game events, auto-scroll via JS interop, and comprehensive unit tests (41 passing).

## Requirements
- [x] Message input and submission (ChatBox stateless component + GamePage actions)
- [x] Message display with usernames and color-coded types
- [x] System messages for all game events (start, next round, end, timeout, join, leave)
- [x] Auto-scroll to latest message via Hologram JS interop
- [x] Spam protection with client-side rate limiting (3 msgs / 5s window, 3s cooldown)
- [x] Close guess detection (Levenshtein distance + substring matching)
- [x] Guess obfuscation — close guesses shown in yellow as visual hint
- [x] Message history limit (50 messages, oldest dropped)
- [x] Keyboard support (Enter to send)
- [x] Unit tests covering all chat features

## Implementation Details

### 1. ChatBox Component Refactor (`lib/scrawly_web/components/chat_box.ex`)
- Converted to a proper **stateless** presentation component (removed dead action handlers)
- Events bubble to GamePage: `$change="update_message"`, `$click={:send_message}`, `$keydown={:handle_keydown}`
- Added props: `is_drawer`, `rate_limited`
- Five message type renderings:
  - `:system` — gray info bar
  - `:correct_guess` — green success bar
  - `:round_complete` — blue completion bar
  - `:close_guess` — yellow-highlighted player message
  - `:chat` — default gray player message
- Rate limit warning shown when `rate_limited` prop is true
- Dynamic placeholder based on `is_drawer` prop

### 2. Event Propagation Fix (GamePage)
- Added `action(:handle_keydown, ...)` to GamePage (Enter key triggers send_message)
- Changed ChatBox input from `$input` to `$change` per Hologram forms docs (fires every keystroke on text inputs)
- All chat state management lives in GamePage; ChatBox is purely presentational

### 3. System Messages
- Helper: `add_system_message(component, message, type \\ :system)` — creates system message map, prepends to chat_messages, triggers auto-scroll
- Game started: "Game started! Round N — {drawer} is drawing"
- Next round: "Round N — {drawer} is drawing"
- Game ended: "Game over! Final scores are in." (type: `:round_complete`)
- Round timeout: "Time's up! The word was: {word}"
- Player joined: "{username} joined the room"
- Player left: "{username} left the room"

### 4. Close Guess Detection
- `close_guess?(guess, word)` checks:
  - Guess contains the word as substring
  - Word contains guess as substring (guess length >= 3)
  - Same length with Levenshtein distance <= 2
  - Off-by-one length with Levenshtein distance <= 2
- Pure Elixir `levenshtein/2` implementation using dynamic programming with `String.graphemes/1`
- Only active for non-drawer, non-guessed players during active rounds

### 5. Rate Limiting
- Client-side rate limiting (no server roundtrip needed)
- State: `rate_limited` (boolean), `message_timestamps` (list of monotonic timestamps)
- Window: 3 messages in 5 seconds triggers rate limit
- Cooldown: 3 seconds via `put_action(:clear_rate_limit, delay: 3_000)`
- Old timestamps (> 5s) pruned on every send attempt
- Messages silently dropped while rate-limited (input preserved)

### 6. Auto-scroll via JS Interop
- `use Hologram.JS` added to GamePage
- `action(:scroll_chat, ...)` uses `JS.exec(~JS"...")` to scroll `#chat-messages` div to bottom
- Helper: `update_chat_and_scroll(component, messages)` chains state update + delayed scroll (50ms)
- Applied to all paths that modify chat_messages

## Files Changed
- `lib/scrawly_web/components/chat_box.ex` — Stateless component refactor, new message types
- `lib/scrawly_web/pages/game_page.ex` — Rate limiting, system messages, close guess detection, auto-scroll, keyboard handling
- `test/scrawly_web/components/chat_system_test.exs` — 41 unit tests

## Test Coverage
- Message submission flow (5 tests)
- Correct guess detection (9 tests)
- Close guess detection (8 tests)
- Rate limiting (5 tests)
- System messages for game events (4 tests)
- Round complete / all guessed (3 tests)
- Message history management (2 tests)
- Keyboard handling (2 tests)
- Update message (2 tests)
- **Total: 41 tests, 0 failures**
