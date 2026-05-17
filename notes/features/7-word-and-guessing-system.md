# Feature: Word and Guessing System

## Summary
Complete word management with difficulty categorization, smart selection with exclusion, progressive hint reveals, chat-based guess validation, time-based scoring, and auto-round-end when all players guess correctly.

## Requirements
- [x] Word difficulty categorization (easy/medium/hard)
- [x] Smart word selection with weighted difficulty and exclusion of recently used words
- [x] Progressive hint system revealing letters over time (80s -> 0s)
- [x] Chat message parsing for guess validation (case-insensitive, trimmed)
- [x] Time-based scoring (50-500 points based on speed)
- [x] Multiple correct guess handling with drawer bonus
- [x] Auto-end round when all guessers guess correctly
- [x] ScoreBoard displaying ranked player scores
- [x] ChatBox displaying system messages for correct guesses
- [x] Unit tests for all systems

## Implementation Details

### 1. Word Resource Enhancement (`lib/scrawly/games/word.ex`)
- Added `:difficulty` attribute (`:easy`, `:medium`, `:hard`) with default `:medium`
- Categorized 100 words: 30 easy, 35 medium, 35 hard
- Added `list_by_difficulty` read action with filter expression
- Updated `seed_words/0` to include difficulty when creating words

### 2. Smart Word Selection (`lib/scrawly/games.ex`)
- `get_random_word/1` accepts `difficulty:` and `exclude:` options
- Weighted random: 30% easy, 50% medium, 20% hard
- Falls back to unfiltered pool if exclusion eliminates all candidates
- Added `get_words_by_difficulty` code interface on domain

### 3. Word Hint System (`lib/scrawly/games/word_hints.ex`)
- `generate_hint(word, time_left)` — progressive reveal:
  - 80-60s: All underscores
  - 60-40s: First letter
  - 40-20s: First and last letter
  - 20-0s: First, last, and one deterministic middle letter
- Deterministic middle letter via `:erlang.phash2/2` (consistent across ticks)
- Spaces always visible; underscore count shows word length

### 4. Guess Validation (`lib/scrawly_web/pages/game_page.ex`)
- `send_message` action checks if message matches `current_word` (case-insensitive, trimmed)
- Drawers cannot guess; already-guessed players' messages treated as regular chat
- Correct guess triggers system message, hides actual word from chat
- Score awarded immediately in client state and persisted via `update_score` command

### 5. Scoring System
- Formula: `base(50) + (time_left * 450 / 80)` = 50-500 points
- Drawer bonus: 50 points per correct guesser when all guess
- Scores persisted to User resource via Ash `update_score` action

### 6. Auto-End Round
- `maybe_end_round/2` checks if all non-drawer players guessed correctly
- Awards drawer bonus, sets `time_left` to 0 to trigger "Next Round" button

### 7. UI Updates
- **ScoreBoard**: Displays ranked player list sorted by score descending
- **ChatBox**: Renders system messages (correct guess, round complete) with distinct styling

## Files Modified
- `lib/scrawly/games/word.ex` — difficulty attribute, categorized word list
- `lib/scrawly/games.ex` — smart word selection, `get_words_by_difficulty` interface
- `lib/scrawly/games/game.ex` — `used_words` argument on `start_round`
- `lib/scrawly/games/word_hints.ex` — new module for progressive hints
- `lib/scrawly_web/pages/game_page.ex` — guess validation, scoring, auto-end, hint integration
- `lib/scrawly_web/components/score_board.ex` — actual score display with ranking
- `lib/scrawly_web/components/chat_box.ex` — system message rendering

## Files Created
- `lib/scrawly/games/word_hints.ex`
- `test/scrawly/games/word_hints_test.exs` (16 tests)
- `test/scrawly/games/guessing_test.exs` (13 tests)

## Tests
46 tests, 0 failures across:
- `test/scrawly/games/word_test.exs` — difficulty categorization, smart selection, exclusion
- `test/scrawly/games/word_hints_test.exs` — hint generation, hidden display, edge cases
- `test/scrawly/games/guessing_test.exs` — scoring formula, guess matching, DB persistence, game flow
- `test/scrawly/games/game_flow_test.exs` — existing round flow tests (fixed pre-existing User create issue)
