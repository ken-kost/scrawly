# Implementation report: Bart's feedback, Hologram 0.12, drawing, QA

Branch `delegate-realtime-to-framework`, from `dc70160` to the commit that adds this report.
Work done 2026-11-14/15. Every change is a separate commit with tests.

| | Start (`dc70160`) | End |
|---|---|---|
| Elixir / OTP | 1.18.4 / 26.2.2 | 1.19.7 / 28.3.3 |
| Hologram | 0.9.2 | 0.12.8 |
| Tests | 265 | 1023 (plus 20 node tests for the JS modules) |
| Board tasks | 0 / 22 | 22 / 22 completed |

Diff: 202 files changed, about +29.9k / −6.6k lines (about 16k of the added lines are tests).

---

## 1. Bart's feedback: what was done

| # | Feedback | Status | Where |
|---|---|---|---|
| 1 | The current word is in every player's page state and in the room payload; keep it on the server and check guesses in a command | **Done.** `RoomServer.View` builds every payload; only the drawer's view carries the word or choices, and the drawer's private data goes to its own `{:room_player, room, user}` channel. A single `:submit_guess` command checks guesses inside the room process. | #3 `0c89b9c`, #4 `93b4616`, #18 `d7b6162`, QA batch 2 (lines containing the word are suppressed) |
| 2a | `record_correct_guess` gives points without seeing the guess | **Done.** Removed; scoring happens once, server-side, from the guess text. | #3 |
| 2b | Commands take `user_id` / `player_id` / `is_creator` from params; read the user with `get_session` | **Done.** `ScrawlyWeb.Auth` (session-derived identity), `RoomServer.authorize/3`; later backed by middleware. Every command also validates its params and ends in a deny catch-all. | #2 `1504b31`, #5 `99dfcb6`, #15 `6531497`, QA batch 1 |
| 2c | `dissolve_room` on the score page has no check | **Done.** Creator-only, enforced in the room process. | #2 |
| 3a | Upgrade to 0.12 | **Done.** 0.9.2 → 0.9.3 → 0.12.8 on Elixir 1.19.7 / OTP 28.3.3 (Dockerfile, CI, `.tool-versions`). | #12 `beefe8b` |
| 3b | Use Realtime instead of the channel + `poll_room` chain | **Done** for room state, lobby and chat: no polling left, broadcasts are sequenced, gaps trigger one `:resync_room`. **Measured no-go** for live stroke chunks: they stay on the hardened Phoenix channel. | #18 `d7b6162`, #19 `fd6557a`, #21 `3e77902` |
| 3c | Send the round deadline once and count down on the client | **Done.** The 1 Hz tick is gone; the room sends remaining ms and the client counts down with a delayed action. A quiet 60 s round went from 62 broadcasts (about 115 KB per tab) to 4 (about 8 KB). | #17 `6f1fa53` |
| 4 | The score page countdown does `Process.sleep` in a command; use a delayed action | **Done.** A deadline-anchored `put_action(..., delay:)` chain; no server work per second. | #9 `5b2bfc8` |
| 5a | `<window $key_down.n="show_create_room" />` can replace `home_keybinds.mjs` | **Done.** Both `.mjs` keyboard files deleted. `<window>` bindings with typing guards on every form, plus Escape and click-outside to close modals. | #16 `390adb8` |
| 5b | Middleware can load the current user once instead of in every init | **Done.** `LoadCurrentUser`/`RequireUser` through a `ScrawlyWeb.Page` base. One users and one tokens query per page load; the session token is checked, so revocation signs other browsers out. | #15 `6531497` |

## 2. The other requests

### Hologram update and new features
- **Upgrade (#12):** toolchain and dependency pin; compiler order; `Plug.Static` cleanup; `prevent_default` on the canvases. The smoke test also found two app bugs (`497d229`).
- **AI rules (#13):** `CLAUDE.md`'s Hologram section is generated from Hologram 0.12.8's `usage-rules.md` (`mix usage_rules.sync`); the old `usage-rules/` folder is gone.
- **0.10–0.12 features adopted:**
  - middleware (#15);
  - `<window>` / key filters / `$click_outside` (#16);
  - delayed actions (#9, #17);
  - Realtime channels (#18, #19);
  - prop `required:` / `values:` contracts, `component.props`, struct-free client data and a `max_bundle_size` guard (#14).

### Drawing
- **The flicker you reported (demo board): fixed.** The finished stroke used to disappear until the server echo arrived. It is now committed locally in the same JS task that clears the in-progress line, then confirmed or rolled back. Frame probe: stroke missing in 25 of ~133 frames before the fix, 0 after (and still 0 after the later stroke-engine rewrite). This also fixed a socket leak: every visit to Home opened another demo socket. `896d461`
- **In-game canvas sync (#8):**
  - viewers now see strokes live (chunks used to be dropped);
  - stroke ids and undo by id;
  - drawer operations are sent in order and acknowledged;
  - reloads and reconnects no longer wipe strokes.
- **Native stroke engine (#20):**
  - pointer capture;
  - correct coordinates at any canvas width (they were up to ~220 px off);
  - coalesced events and batched rendering;
  - smoothing, dots for taps, long strokes split under the server cap;
  - no Hologram action per pointer move.
- **Drawer and phase rules (#5):** only the drawer can draw, during the drawing phase, with validated strokes and an authorised channel.

### Recovery codes (your request: reset only)
`3b53ce7` (#6):
- A 100-bit code is shown once at registration and at guest upgrade; only its bcrypt hash is stored.
- "Forgot password?" resets the password with email + code. The code is never a sign-in credential.
- A reset revokes every token, rotates the code and signs you in.
- Wrong email, wrong code, guest and code-less accounts all get the same error after one bcrypt check; attempts are throttled.
- The profile page shows the code status and regenerates the code with your password.
- Since #15, a reset or password change signs out your other browsers.

### Found during the work
- **Registration takeover (#1, `7e543fe`), critical.** Registering an existing email returned that account with a fresh token. Confirmed at runtime and fixed. The same code is on `master`; see §6.
- **Anonymous entry points (#11):**
  - lobby nickname spoofing;
  - the reserved "System" username;
  - demo-board validation and rate limits;
  - `/guest` reusing an existing session;
  - room input limits.
- **Init redirects (#10):** `put_page` from `init` never redirected, and `/game/<unknown>` crashed.
- **Build artifacts (#22):** `.holo_dev` and digested statics untracked. The Docker context went from about 1.99 GB to about 1.2 MB, measured with Docker's own pattern matcher.

## 3. QA (requested after the tasks)

Four independent read-only passes, each finding proven with a test or a runtime probe:

1. **Accounts and auth review:** 9 hardening items, no bypass or takeover.
2. **Game and realtime review:** 15 defects, several older than this branch.
3. **Client code review:** 3 significant defects plus 10 low ones, no XSS.
4. **End-to-end browser pass:** 3 full games, all pages and roles, at 390 and 1440 px. It found 3 real bugs plus pre-existing and cosmetic issues.

Then a health check, which was clean apart from one file Elixir 1.19's formatter now formats differently.

Everything was fixed in four batches, each with regression tests:

| Batch | Commit | Highlights |
|---|---|---|
| Auth hardening | `f0944d2` | Malformed or forged commands no longer crash with a 500 and write the session cookie and JWT to the log (every command is total, and a log redactor strips session data). Sign-in throttled per email and per IP; unused auth routes removed; sign-out is a CSRF-checked command. The game socket uses a short-lived socket token, not the session JWT, and sockets disconnect on revocation. Passwords and codes are never kept in snapshot-able page state; profile errors never echo input. Recovery reset and regenerate are single-use under concurrency; the throttle is atomic. `/guest` validates `return_to` and is rate-limited. The session cookie is `secure` in prod. |
| Game robustness | `49b7731` | Common room settings (e.g. 3 players × 5) could never start, because the round cap was 12. Games are now whole rotations, capped at 24 rounds. A room restarted mid-game (crash or deploy) returns to the lobby instead of hanging. Dissolved rooms can't come back. Chat containing the word is suppressed. Empty word tables fall back to the built-in list. The AI refill no longer blocks the room. The drawer leaving ends the turn; fewer than 2 players ends the game; nobody is skipped in the rotation. Rooms stay joinable after a game. Timers and Game rows are closed on dissolve. The curated 900-word seed is idempotent. |
| Payload limits and abuse | `32d0ef8` | Byte caps on all user text (megabyte chat lines were possible). Demo board uses the same stroke validators as the game. WebSocket frame and request body limits. Spectator rate limits, quieter chat, and expiry after about 1 min without a tab; lobby players after 5 min. Undo broadcasts only the stroke id. Stroke-op rate limit. Capped round replays. |
| Client robustness and UI | `7f5dc09` | Back/Forward no longer crashes pages: restored pages kept the old page's subscriptions. Drawing tools no longer carry over to the next game (an eraser left on made invisible strokes). The score page countdown only runs for the room's latest game and its players. Long chat words no longer widen the page (it reached 2,546 px). The header and Home fit 320–390 px screens. Cosmetic fixes: tie wording, "game not found", copy feedback, avatars, Past games placement. |

## 4. Verification

Final pass on the finished branch (all of it re-run after the last QA batch):

| Check | Result |
|---|---|
| `mix precommit` (warnings as errors, unused-lock check, format, tests) | pass: 1023 tests, 0 failures |
| `mix test` three more times (seeds 973234, 614956, 300439) | 1023 / 0 failures each; nothing flaky |
| Forced recompile with warnings as errors; `ash.codegen --check` | clean |
| Node tests for the JS modules (`node --test test/js/*.test.mjs`, also run from `mix test`) | 20 / 20 |
| Clean Hologram bundle build with the `max_bundle_size` guard | pass (runtime 671 KB, largest page bundle 571 KB, limit 840 KB) |
| Prod release built in a separate worktree following the Dockerfile's steps, booted against a throwaway DB | pass: pages 200, missing game/results pages handled, bundles 200 with gzip and long cache, signed-out `/profile` 302, cookie `secure; HttpOnly; SameSite=Lax`, 0 console errors |
| Browser regression smoke | pass: Home at 1440 and 390 px with no overflow; lobby chat; demo-board flicker probe (0 invisible frames); N and Escape; register, recovery panel, sign-out (a command; GET routes 404), wrong and right password, recovery reset, password change; a full 2-player game with exact stroke positions, undo, guesses, both rounds, score page and return to the lobby; the word never in the guesser's HTML, responses or storage; Back/Forward with no console errors; forged commands denied with nothing sensitive in the log |
| Board | 22 / 22 completed |

Measurements from the tasks:
- Demo-board flicker: stroke missing in 25 of ~133 frames before, 0 after.
- Room broadcasts in a quiet 60 s round: 62 before, 4 after.
- Idle Home tab: 12 command POSTs per minute before, 3 after.
- Stroke position error: up to ~220 px before, ≤ 0.02 px after.

## 5. Decisions applied (defaults; change any you disagree with)

- **Spectators:**
  - Signed-in spectators (guest or registered) may chat; a line containing the word is suppressed and spectators never score.
  - Visitors without an account can watch but not join, guess or chat in rooms.
  - Spectators expire after about 1 min without an open tab; lobby players after 5 min (the creator's absence dissolves the room, like leaving). Mid-game players are never removed; the round runs to its deadline.
- **Chat suppression:** lines containing the word as a whole word (normalised) are suppressed during drawing; only the sender gets a hint. "Close guess" feedback is not added.
- **Round reveal:** the word is revealed to everyone at round end, both when time runs out and when everyone has guessed. The letter count counts letters only.
- **Game length:** whole rotations, capped at 24 rounds. The lobby still shows the chosen "N×". `User.score` is the player's score in their current room or game.
- **Lobby chat without an account:** allowed, under a server-assigned `guest_N` name kept in the session.
- **Keyboard:** Escape closes all modals and the accent popover. Click-outside closes only the popover and the drawing viewer (form modals keep their input). No bracket-key brush shortcuts.
- **Live strokes:** stay on the Phoenix channel (measured gate: +33–58 ms p50 at 100 ms RTT, and 3–4× the receiver CPU per chunk). The prototype is kept in `notes/files/realtime-demo-chunks-prototype.patch`.
- **"N online":** counts open tabs on any page (20 s heartbeat, about 45 s TTL).
- **Not changed (your call):** unique usernames; an upgraded guest keeps its `guest-…` username; deploy trigger.

## 6. Needs your action / follow-ups

1. **Production is exposed to the registration takeover until `7e543fe` reaches `master` and is deployed.** The bug is on `master` and `fly.toml` shows a live app.
   - After deploying, rotate `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET`. That evicts any session hijacked before the fix, and signs everyone out.
   - I did not deploy or touch production.
2. **Deploy pipeline:** `.github/workflows/fly-deploy.yml` triggers on `main`, which doesn't exist, so deploys are manual. Prod now expects the `fly-client-ip` header (Fly sets it) for per-IP limits. Override with `CLIENT_IP_HEADER` if needed.
3. **Docker:** `docker build` could not run here (no Docker in WSL). The Dockerfile's steps were run by hand, and a prod release was built and booted. Do one real `docker build` before deploying.
4. **Dependency advisories:** `mix deps.get` reports security advisories for 26 locked packages (ash, phoenix, plug, bandit, phoenix_live_view, …). They were deliberately left out of the upgrade's scope and deserve their own task.
5. **Hologram issues to report upstream:**
   - A command naming one of Hologram's own modules returns a 500, because the module isn't checked. Our log line is redacted.
   - A command name that isn't an existing atom returns a 500 from the deserializer (`binary_to_existing_atom`) before the app's own denial runs. The command is still refused and nothing sensitive is logged.
   - A page that navigated away with `put_page` keeps that navigation in its Back/Forward snapshot and bounces again on restore. Worked around in each page's `:page_shown`.
   - Each pushed Realtime action costs a full page render. That is why the measured gate kept live strokes off Realtime.
6. **Your dev environment:**
   - The dev server runs **detached** (`mix holo`, log `/tmp/holo_research/devserver.log`). The IDE's restart tool uses your terminal's old Elixir 1.18 environment and fails.
   - To take it back into a terminal: `pkill -f "erlang/28.3.3.*mix holo"`, then run `iex -S mix holo` in a **new** terminal (it reads `.tool-versions`).
   - The dev database has no words; run `mix run priv/repo/seeds.exs` to add the curated 900 (it is safe to re-run). Games work without them via the built-in fallback.
   - A QA agent downloaded `scrawly-recovery-code.txt` into the shared browser's Downloads folder; it belongs to a deleted TEST account, so delete it.
   - The picosat NIF under `deps/` was rebuilt for OTP 28.
   - The dev log is at `:debug`, so it contains SQL parameters, including bcrypt hashes. This is dev only; prod logs at `:info`.
   - `bin/scrawly stop` fails under WSL ("Hostname ken is illegal" from `RELEASE_DISTRIBUTION=name` in `rel/env.sh.eex`). It doesn't affect Fly.
   - Pre-existing: the layout links `/assets/css/app.css` without its digest, so the CSS isn't cached long-term.
   - Some ended TEST rooms and TEST users remain in the dev database (all prefixed `TEST`).
7. **Not done:** live stroke chunks on Realtime (measured no-go); "close guess" hints; heartbeat-based removal of players mid-game; real-device touch, Firefox and Safari testing.

## 7. Commits

```
7f5dc09 QA fixes: client robustness and UI
32d0ef8 QA fixes: payload limits and abuse
49b7731 QA fixes: game robustness
f0944d2 QA fixes: auth hardening
59d5fe8 Format lib/scrawly_web.ex with the Elixir 1.19 formatter
68bb0aa Untrack generated artifacts and tighten the Docker build context
3e77902 Keep live stroke chunks on the Phoenix channels after a measured gate
32c080b Build one native stroke engine for both canvases
fd6557a Move the lobby room list, lobby chat and online count to Hologram Realtime
d7b6162 Make the game page push-only: sequenced broadcasts, private drawer channel, resync
6f1fa53 Replace the 1 Hz server tick with deadline-based client countdowns
390adb8 Move keyboard shortcuts to <window> key bindings and add Escape dismissal
6531497 Load the session user once per request in middleware and honour token revocation
777bc9a Post-upgrade hygiene: struct-free client data, prop contracts, dead code
934fa94 Regenerate the Hologram AI rules from 0.12.8 and retire usage-rules/
497d229 Fix duplicated keyboard listeners and stale header after home sign-in
beefe8b Upgrade to Elixir 1.19.7 / OTP 28.3.3 and Hologram 0.12.8
783b4dd Make the complete game flow test exclude already-used words
6953582 Harden the entry points reachable without an account
ff95b10 Make GamePage init-time redirects work for missing, ended and post-game rooms
5b2bfc8 Replace the score page's sleeping tick with a client-side countdown
b1184cd Make in-game drawer and viewer canvases converge
896d461 Fix the demo-board stroke vanishing for a moment after drawing
3b53ce7 Add account recovery codes to reset a forgotten password without email
99dfcb6 Enforce drawer/phase rules and stroke validation for drawing
93b4616 Stop sending the secret word and word choices to non-drawers
0c89b9c Check guesses on the server with one :submit_guess command
1504b31 Derive the acting user from the session and authorize room commands
7e543fe Stop password registration from upserting onto an existing account
(plus the commit adding this report)
```
