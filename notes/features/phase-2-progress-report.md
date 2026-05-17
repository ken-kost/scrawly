# Phase 2 Progress Report

> Generated: 2026-04-10

## Overview

Phase 2 "Enhanced Features" covers features 9-14. This report covers the implementation
of features 13 (Progressive Hint System) and 14 (Enhanced Scoring System), completed
on 2026-04-10.

---

## Feature 12: Advanced Drawing Tools — NOT STARTED

All items remain TODO. No implementation work has been done on:
- Color palette, brush sizes, eraser, undo/redo
- DrawingToolbar component
- Related tests

**Status:** 0% complete (0/15 items)

---

## Feature 13: Progressive Hint System — MOSTLY COMPLETE

### What Was Implemented

**Hint Generation Logic (4/4 items)**

The `Scrawly.Games.WordHints` module was enhanced from a basic 4-stage system to a
full 5-stage progressive hint engine:

| Stage | Elapsed % | What's Revealed |
|-------|-----------|-----------------|
| 0     | 0-25%     | All underscores |
| 1     | 25-50%    | First letter |
| 2     | 50-65%    | First + last letter |
| 3     | 65-80%    | First + last + ~25% of middle (vowels first) |
| 4     | 80-100%   | First + last + ~50% of middle |

Key improvements over the Phase 1 implementation:
- **Vowel priority**: Middle letter reveals prioritize vowels (a, e, i, o, u) as they're
  more helpful for guessing
- **Configurable schedule**: `hint_schedule` option accepts custom threshold percentages
- **More granular stages**: 5 stages instead of 4, with stages 3-4 revealing proportionally
  more letters for longer words
- **Deterministic ordering**: Uses `phash2` for consistent reveals across renders

**Hint Metadata (`hint_info/3`)**

New function returns structured data for UI display:
```elixir
%{stage: 3, revealed_count: 5, total_letters: 9, remaining_count: 4, progress_pct: 56}
```

This is computed server-side in `Commands.poll_and_enrich` and sent to the client.

**UI Updates (2/4 items)**

- Hint progress bar with stage indicator (e.g., "Hint 2/4")
- Remaining letters counter ("5 letters hidden")
- *Not implemented*: Animated letter reveals, visual hint emphasis (CSS animations)

**Test Coverage (5/5 items)**

42 tests in `word_hints_test.exs`:
- Stage progression across all 5 stages
- Vowel priority in middle letter selection
- Determinism verification
- Edge cases (nil, empty, single char, 2-char, multi-word)
- Custom schedule support
- `hint_info` metadata accuracy
- `current_stage` function
- Progressive reveal monotonicity (each stage >= previous)

**Status:** 85% complete (11/15 items, 2 UI animation items remain)

---

## Feature 14: Enhanced Scoring System — MOSTLY COMPLETE

### What Was Implemented

**Scoring Algorithm (4/4 items)**

New `Scrawly.Games.Scoring` module replaces the old flat scoring:

| Component | Old System | New System |
|-----------|-----------|------------|
| Guesser points | `time_left` (1-80) | `50 + (time_left/duration * 450)` = 50-500 |
| Hint penalty | None | -10% per hint stage (stages 1-4) |
| Drawer (all guess) | 0 pts | +50 per guesser + 100 bonus |
| Drawer (some guess) | 0 pts | +50 per guesser |
| Drawer (timeout, none) | -80 pts | -25 pts |
| Drawer (timeout, some) | -80 pts | +50 per guesser (no penalty) |

Key design decisions:
- **Server-side calculation**: `Commands.record_correct_guess` now calculates points
  from RoomServer state instead of trusting client-sent values. This fixes a potential
  score manipulation vector.
- **Hint-scoring integration**: `Scoring.guesser_points_with_hints/3` automatically
  queries `WordHints.current_stage/2` to apply the correct penalty.
- **Reduced drawer penalty**: Changed from -80 to -25 for timeout with no guesses.
  The old penalty was too harsh and discouraged drawing.
- **Per-guesser drawer reward**: Drawers now earn points proportional to engagement.

**Architecture:**

```
GamePage (client)                    Commands (server)
    |                                     |
    |  guess correct                      |
    +---> put_command(:record_correct_guess)
                                          |
                                    RoomServer.get_state()
                                          |
                                    Scoring.guesser_points_with_hints()
                                          |    (queries WordHints.current_stage)
                                          |
                                    RoomServer.update_player_score()
                                    RoomServer.record_guess()
```

Round-end scoring in RoomServer:
```
Timer expires / All guessed
    |
    v
Scoring.drawer_points(correct_count, total_guessers, time_up: bool)
    |
    v
Update drawer score in player list
    |
    v
capture_round_result() with drawer_points
```

**ScoreAnimation Component (1/4 items)**

- Round score summary already existed via `round_results` in RoomServer state
- *Not implemented*: Point gain animations, leaderboard position animations, final celebration

**Test Coverage (4/5 items)**

31 tests in `scoring_test.exs`:
- Speed curve: max/min/mid points, linear scaling, different durations
- Hint penalty: all 5 stages, floor at base points, proportional reduction
- Drawer points: per-guesser, all-guessed bonus, timeout penalty, partial guesses
- Integration: `guesser_points_with_hints` with WordHints
- Scenario tests: early/late guesses, perfect rounds, total scores

7 updated tests in `guessing_test.exs`:
- Scoring formula now uses `Scoring` module directly
- Added drawer scoring tests

**Status:** 70% complete (9/15 items, 3 animation items + 1 test remain)

---

## Test Summary

| Test File | Tests | Focus |
|-----------|-------|-------|
| `word_hints_test.exs` | 42 | 5-stage hints, vowel priority, metadata, config |
| `scoring_test.exs` | 31 | Speed curve, hint penalty, drawer points |
| `guessing_test.exs` | 17 | Scoring integration, guess matching |
| Integration tests | 7 | Full game flow with new hint/scoring (unchanged, pass) |

**Full suite: 282 tests, 0 failures**

---

## What Remains TODO

### Feature 12 — Advanced Drawing Tools (0%)
All 15 items. This is the largest remaining Phase 2 feature.

### Feature 13 — Progressive Hints (2 items)
- [ ] Animated letter reveals (CSS/JS transitions when new letters appear)
- [ ] Visual hint emphasis (highlight newly revealed letters)

### Feature 14 — Enhanced Scoring (5 items)
- [ ] Point gain animations (floating "+250" on correct guess)
- [ ] Leaderboard position change indicators (arrows, highlights)
- [ ] Final score celebration (confetti, winner announcement)
- [ ] Test score animation triggers

### Phase 2 Integration Tests (0/6)
- [ ] Test private room creation and joining via link
- [ ] Test custom word list in complete game
- [ ] Test all drawing tools in multiplayer setting
- [ ] Test hint system timing and reveals
- [ ] Test avatar persistence across sessions
- [ ] Test enhanced scoring with multiple players

---

## Phase 2 Completion Summary

```
Feature                             Done / Total   Pct
─────────────────────────────────── ──────────── ─────
9.  Private Room System              0/15          0%
10. Custom Word Management           0/15          0%
11. Avatar System                    0/15          0%
12. Advanced Drawing Tools           0/15          0%
13. Progressive Hint System         11/15         73%
14. Enhanced Scoring System          9/15         60%
─────────────────────────────────── ──────────── ─────
Phase 2 Overall                     20/90         22%
Phase 2 Integration Tests            0/6           0%
```

---

## Files Changed

### New Files
- `lib/scrawly/games/scoring.ex` — Scoring calculation module (95 lines)
- `test/scrawly/games/scoring_test.exs` — Scoring tests (196 lines)

### Modified Files
- `lib/scrawly/games/word_hints.ex` — Enhanced from 136 to 188 lines (+5 stages, vowel priority, hint_info, configurable schedule)
- `lib/scrawly/games/room_server.ex` — Updated round-end scoring to use Scoring module
- `lib/scrawly_web/pages/game_page/commands.ex` — Server-side score calculation, hint_info enrichment
- `lib/scrawly_web/pages/game_page.ex` — hint_info state, progress bar UI, updated calculate_points estimate
- `test/scrawly/games/word_hints_test.exs` — Expanded from 114 to 297 lines
- `test/scrawly/games/guessing_test.exs` — Updated scoring tests to use Scoring module
- `plan.md` — Updated checkboxes for features 13 and 14
