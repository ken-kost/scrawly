# Scrawly

Scrawly is a real-time multiplayer drawing and guessing game. One player draws
a word, and everyone else races to guess it in the chat. It is written in
Elixir with [Hologram](https://hologram.page), [Phoenix](https://www.phoenixframework.org)
and [Ash](https://ash-hq.org), and it runs at
[scrawly.fly.dev](https://scrawly.fly.dev).

- **Rooms:** Up to 12 players, a lobby with chat, invite links and short room
  codes, and watchers who follow a game without playing.
- **Turns:** The drawer picks one of three words (easy, medium, or hard), and
  letter hints appear as the round runs. Points depend on how fast you guess,
  your guessing order, and the word's difficulty.
- **Words:** A curated list of 1,422 words and phrases in themes, or a list
  that an AI writes for a room from the host's own theme.
- **Drawing:** Brush, eraser, fill, colour picker, any colour, sizes from 1
  to 40, and undo, with mouse, pen, or touch input.
- **Home page:** A shared drawing board that anyone can draw on, a lobby
  chat, the open rooms, and a live count of players online.
- **Accounts:** Play as a guest, or register with an email and a password.
  Recovery codes replace password-reset emails.

## Tech stack

| Layer | Technology |
|---|---|
| Language and runtime | Elixir 1.19.7 on Erlang/OTP 28.3.3 |
| UI, client state and realtime | Hologram 0.12: pages and components in Elixir, compiled to JavaScript |
| Web server | Phoenix 1.8 on Bandit |
| Domain and persistence | Ash 3 and AshPostgres on PostgreSQL |
| Authentication | AshAuthentication (password strategy, sign-in tokens) |
| AI word lists | AshAi and LangChain with the OpenAI API |
| Drawing | SVG canvases driven by native JavaScript modules through Hologram JS interop |
| Live stroke stream | A Phoenix channel over WebSocket |
| Styling | Tailwind CSS 4 and daisyUI |
| Hosting | Fly.io, one region (`fra`), deployed by GitHub Actions |

## Get started

### Prerequisites

Install the following:

- Erlang/OTP 28.3.3 and Elixir 1.19.7. The versions are pinned in
  `.tool-versions`, so `asdf install` or `mise install` installs them.
- PostgreSQL. The development configuration connects to `localhost` as user
  `postgres` with password `postgres`. CI uses PostgreSQL 16.
- Node.js 20 or later, with npm. The Hologram compiler runs `npm install` for
  its client bundles, and the JavaScript unit tests run on `node --test`.

### Run the app locally

1. Clone the repository and change to its directory:

   ```sh
   git clone https://github.com/ken-kost/scrawly.git
   cd scrawly
   ```

1. Install the dependencies, create and migrate the database, build the
   assets, and load the word list:

   ```sh
   mix setup
   ```

1. Start the server with Hologram enabled:

   ```sh
   mix holo
   ```

   To get an IEx shell as well, run `iex -S mix holo`.

1. Open [http://localhost:4123](http://localhost:4123).

To play a game on your own, open a second browser profile or a private
window, so that you have two players in the room.

> [!IMPORTANT]
> Start the server with `mix holo`, not `mix phx.server`. Hologram runs in
> `dev` and `test` only when `HOLOGRAM_START=1` is set, and `mix holo` sets it.
> Without it, every page returns a `Phoenix.Router.NoRouteError`.

### Turn on AI word lists (optional)

Rooms with **your own theme** ask OpenAI for their words. To use them locally,
export your key before you start the server:

```sh
export OPENAI_API_KEY="sk-..."
export OPENAI_ORG_ID="org-..."   # optional
mix holo
```

Without a key, these rooms fall back to the built-in word list, and the room
tells its host so.

### Development URLs

| URL | What it is |
|---|---|
| `http://localhost:4123` | The app |
| `http://localhost:4123/dev/dashboard` | Phoenix LiveDashboard: metrics, processes, and request logging |
| `http://localhost:4123/dev/mailbox` | Swoosh mailbox preview |
| `http://localhost:4123/admin` | AshAdmin: browse and edit the Ash resources |
| `http://localhost:4007` | LiveDebugger |
| `http://localhost:4123/tidewave/mcp` | Tidewave MCP server for coding agents |

## Common tasks

| Command | What it does |
|---|---|
| `mix holo` | Starts the development server with Hologram enabled. |
| `mix test` | Creates and migrates the test database, then runs the ExUnit suite and the JavaScript unit tests. |
| `mix precommit` | Compiles with warnings as errors, removes unused dependencies from the lock file, formats the code, and runs the tests. Run it before every commit. |
| `HOLOGRAM_START=1 mix compile` | Builds the Hologram page bundles, as CI does. It catches client compilation errors that `mix test` doesn't, because tests run with Hologram off. |
| `node --test test/js/*.test.mjs` | Runs only the JavaScript unit tests. |
| `mix ash.codegen <name>` | Generates migrations after you change an Ash resource. |
| `mix db.reset` | Drops, recreates, and migrates the development database, then loads the words. |
| `mix run priv/repo/seeds.exs` | Syncs the `words` table with `priv/words/words.csv`. |
| `mix scrawly.word_report > report.csv` | Prints the words that play too hard, too easy, or are rarely picked. |

## Architecture

### Overview

Scrawly is one Elixir application. Hologram renders each page on the server,
then runs the page in the browser as Elixir compiled to JavaScript. Client
state lives in the browser. The browser reaches the server in three ways:

- **Commands** are Hologram's HTTP/2 requests, used for every change, such as
  joining a room, sending a guess, or completing a stroke.
- **Realtime broadcasts** are Hologram actions that the server pushes over a
  Server-Sent Events stream, such as room updates, chat lines, and completed
  strokes.
- **A Phoenix channel** carries the live stroke stream, the in-progress line
  that other players watch as the drawer draws, at about 20 messages a second.

```mermaid
flowchart LR
  subgraph Browser
    HR["Hologram runtime<br>pages, components, actions"]
    JS["Native canvas modules<br>stroke_engine.mjs, drawing_manager.mjs,<br>demo_board.mjs, fill_tool.mjs"]
    HR <-- "JS interop" --> JS
  end

  subgraph Endpoint["Phoenix endpoint on Bandit"]
    ROUTER["Hologram.Router<br>page renders, commands,<br>Realtime stream"]
    SOCKET["UserSocket<br>game:* and demo:board channels"]
  end

  subgraph Processes["OTP processes"]
    RS["RoomServer<br>one per room"]
    DBS["DemoBoardServer"]
    LCS["LobbyChatServer"]
    OT["OnlineTracker"]
  end

  subgraph Ash["Ash domains"]
    GAMES["Scrawly.Games"]
    ACCOUNTS["Scrawly.Accounts"]
  end

  PG[("PostgreSQL")]
  OPENAI["OpenAI API"]

  HR -- "commands over HTTP/2" --> ROUTER
  ROUTER -- "broadcasts over SSE" --> HR
  JS <-- "live strokes over WebSocket" --> SOCKET
  ROUTER --> RS
  ROUTER --> LCS
  ROUTER --> OT
  ROUTER --> ACCOUNTS
  SOCKET --> RS
  SOCKET --> DBS
  RS --> GAMES
  GAMES --> PG
  ACCOUNTS --> PG
  GAMES -- "AI word lists" --> OPENAI
```

Everything except the live stroke stream uses Hologram. The stream stays on a
Phoenix channel because a measurement showed that over Hologram Realtime each
chunk would cost an HTTP command, an acknowledgement before the next chunk,
and a page render on every other player's browser. For the measurements, see
`REALTIME_MIGRATION_REPORT.md`.

The canvases are plain SVG that native JavaScript modules own. Pointer input
never runs a Hologram action or a re-render. The page sends the modules its
tool, colour, and size through JS interop, and the modules hand finished
strokes back to the page.

### Processes

Every room is a `RoomServer` GenServer under a `DynamicSupervisor`, found by
its ID in a `Registry`. The room process is the single source of truth for its
players, phase, chat, and canvas. It writes the lasting results through Ash.

```mermaid
flowchart TD
  SUP["Scrawly.Supervisor<br>one_for_one"]
  SUP --> TEL["ScrawlyWeb.Telemetry"]
  SUP --> REPO["Scrawly.Repo"]
  SUP --> DNS["DNSCluster"]
  SUP --> PUBSUB["Phoenix.PubSub"]
  SUP --> REG["Scrawly.RoomRegistry<br>room ID to process"]
  SUP --> ROOMS["Scrawly.RoomSupervisor<br>DynamicSupervisor"]
  ROOMS --> R1["RoomServer"]
  ROOMS --> R2["RoomServer"]
  SUP --> TASKS["Scrawly.TaskSupervisor<br>AI word refills"]
  SUP --> THR["Accounts.Throttle<br>sign-in and guest limits"]
  SUP --> ONLINE["OnlineTracker<br>players online"]
  SUP --> BOARD["DemoBoardServer<br>home page board"]
  SUP --> EP["ScrawlyWeb.Endpoint"]
  SUP --> AUTH["AshAuthentication.Supervisor"]
  SUP --> LOBBY["LobbyChatServer<br>lobby chat"]
```

Hologram has no disconnect hook, so presence works by heartbeat. Every open tab
pings `OnlineTracker` every 20 seconds. A room asks the tracker which of its
members still have a live tab, and removes the ones that have been gone for a
grace period.

### Room lifecycle

A room's status is stored in the database. Inside a game, the room process
moves through three phases for every turn.

```mermaid
stateDiagram-v2
  [*] --> lobby: host creates the room
  lobby --> playing: host starts with 2 or more players
  state playing {
    [*] --> choosing
    choosing --> drawing: drawer picks a word, or 15 s pass
    drawing --> round_end: time is up, everyone guessed, or the drawer left
    round_end --> choosing: after 5 s, the next drawer in the queue
  }
  playing --> post_game: last turn ends, or fewer than 2 players remain
  post_game --> lobby: after 30 s, if the host is still there
  post_game --> ended: after 30 s, if the host left
  lobby --> ended: host leaves
  ended --> [*]
```

Nothing ticks on the server while a turn runs. The room keeps monotonic
deadlines and sends the remaining milliseconds in its updates, and each browser
counts down on its own clock. The room times its own turns with
`Process.send_after/3` and cancels the timers when a turn or a game ends.

The following timeline shows one turn with the default 60-second round. Hints
reveal about 35% of the letters, in two batches, at 37.5% and 68.75% of the
round.

```mermaid
gantt
  title One turn with a 60-second round
  dateFormat x
  axisFormat %M:%S
  section Drawer
  Choose one of 3 words      : 0, 15000
  Draw                       : 15000, 75000
  section Guessers
  All letters hidden         : 15000, 37500
  First batch of letters     : 37500, 56250
  Second batch of letters    : 56250, 75000
  section Room
  Round summary              : 75000, 80000
```

A game gives every player the same number of turns. The host sets the round
length (60 to 300 seconds), the turns per player (1 to 5, at most 24 turns
a game), the answer kind (words, phrases, or mixed), and the word source (themes from the
built-in list, or an AI list from the host's own theme).

### Drawing

A stroke travels two ways. While the drawer draws, the stroke engine sends the
in-progress line in chunks over the game channel, which relays them straight to
the other players. When the drawer lifts the pointer, the page sends the
finished stroke as a Hologram command, and the room validates it, stores it,
and broadcasts it to everyone.

```mermaid
sequenceDiagram
  autonumber
  participant D as Drawer's browser
  participant GC as GameChannel
  participant RS as RoomServer
  participant P as Other browsers

  loop About 20 times a second while drawing
    D->>GC: stroke chunk
    GC->>RS: drawing_allowed? (cached for 2 s per stroke)
    GC->>P: relay the chunk
  end
  Note over D: Pointer up
  D->>RS: complete_stroke command
  RS->>RS: Validate with StrokeRules and store
  RS-->>D: :stroke_completed with the next seq
  RS-->>P: :stroke_completed with the next seq
```

Every broadcast on a room's public channel carries a sequence number, one
higher than the last. Hologram Realtime delivers at most once and never
replays, so a page that sees a gap in the numbers asks for a full snapshot.

The drawer's browser commits each stroke locally first, so the drawer never
waits for the server. Fills work the same way: the fill tool works out the
closed shape in a web worker (`priv/static/fill_worker.mjs`) and sends it as a
stroke with `fill: true`.

### Guessing

The secret word never reaches a guesser's browser before they guess it. The
room checks every chat line on the server and answers in one of four ways.

```mermaid
sequenceDiagram
  participant G as Guesser's browser
  participant RS as RoomServer
  participant All as Everyone in the room

  G->>RS: submit_guess command
  alt The line is the word
    RS->>RS: Score the guess
    RS-->>All: :chat_appended "guessed the word" and :room_delta with scores
    RS-->>G: The word, on the guesser's private channel
  else The line is one edit away from the word
    RS-->>G: "is close" reply, to the guesser alone
  else The line contains the word
    RS-->>G: Line held back, to the guesser alone
  else Any other line
    RS-->>All: :chat_appended
  end
```

A room uses two Hologram Realtime channels:

- `{:room, room_id}` is public. Every game page subscribes to it.
- `{:room_player, room_id, user_id}` is private to one player. The drawer's
  word choices and the word go only here.

A guesser earns `(50 + speed bonus + order bonus) × difficulty multiplier`.
The speed bonus is up to 450 points for the time left, the order bonus is 50
points for the first correct guess and 25 for the second, and the multiplier
is ×1, ×1.25, or ×1.5 for an easy, medium, or hard word. The drawer earns the
mean of the guessers' points.

### Data model

Ash resources in two domains, `Scrawly.Games` and `Scrawly.Accounts`, map to
these PostgreSQL tables.

```mermaid
erDiagram
  users ||--o{ rooms : creates
  rooms |o--o{ users : "has as players"
  rooms ||--o{ games : runs
  games ||--o{ game_results : records
  users ||--o{ game_results : earns

  users {
    uuid id PK
    ci_string email
    string username
    boolean is_guest
    uuid current_room_id FK
    string avatar_id
  }
  rooms {
    uuid id PK
    string code
    atom status
    atom word_source
    atom answer_kind
    integer round_duration
    uuid creator_id FK
  }
  games {
    uuid id PK
    uuid room_id FK
    atom status
    integer current_round
    integer total_rounds
    map_array round_details
  }
  game_results {
    uuid id PK
    uuid game_id FK
    uuid player_id FK
    integer score
  }
  words {
    uuid id PK
    string text
    atom difficulty
    atom theme
  }
  word_stats {
    string text PK
    integer offered
    integer picked
    integer correct
  }
  tokens {
    string jti PK
    string subject
    string purpose
    utc_datetime expires_at
  }
```

- `words` is a copy of `priv/words/words.csv`. Every deploy syncs the table
  with the file. For the editorial rules, see `priv/words/README.md`.
- `word_stats` counts how each curated word plays, so its difficulty can be
  checked against real games.
- `tokens` holds the sign-in tokens. Signing out, changing the password, or
  resetting it with a recovery code revokes them, which signs out the other
  browsers too.
- The canvas and chat of a running game live in the room process, not in the
  database. A finished round's strokes are saved in `games.round_details` for
  the results page.

### Security

- Identity comes from the server session, never from command parameters.
  Every page runs `ScrawlyWeb.Middleware.LoadCurrentUser`.
- `RoomServer.View` decides what each viewer may see. Hologram puts page state
  into the HTML, so the word and the drawer's choices are never part of any
  public state.
- The Phoenix socket uses short-lived tokens tied to the session's sign-in
  token, never the sign-in token itself.
- Every command checks the shape of its parameters. Strokes, chat lines,
  sign-ins, guest accounts, and board events are size-checked and
  rate-limited.

## Project layout

```text
lib/
  scrawly/
    accounts/            Users, tokens, recovery codes, sign-in throttle
    games/               Rooms, games, words, scoring, hints, stroke rules
      room_server.ex     The room process
      room_server/       Game flow, broadcasts, and per-viewer views
  scrawly_web/
    pages/               Hologram pages (*.ex) and their native modules (*.mjs)
    components/          Hologram components: canvas, toolbar, chat, scores
    layouts/             AppLayout: header, sign-in, theme, presence ping
    channels/            UserSocket, GameChannel, DemoBoardChannel
    middleware/          Page middleware for the current user
assets/                  Tailwind CSS and the Phoenix JavaScript entry point
priv/
  repo/migrations/       Database migrations, generated by mix ash.codegen
  words/                 words.csv, the curated word list, and its rules
  static/                Static files, including the fill worker
test/
  scrawly/               Domain and room tests, including multiplayer flows
  scrawly_web/           Page, command, channel, and security tests
  js/                    JavaScript unit tests (node --test)
bench/                   Drawing benchmarks; see bench/README.md
rel/overlays/bin/        Release scripts: server and migrate
config/                  Configuration; runtime.exs reads production secrets
```

## Testing

Run the whole suite:

```sh
mix test
```

The suite has about 1,500 ExUnit tests and 280 JavaScript tests.
`test/scrawly_web/js_unit_test.exs` runs the JavaScript tests as part of
`mix test` and skips them when `node` is not on your `PATH`.

Tests run with Hologram turned off: `Hologram.Router` passes requests through,
and `test/test_helper.exs` starts `Hologram.PubSub` so that broadcasts do
nothing. To check that the client bundles compile, run
`HOLOGRAM_START=1 mix compile`.

The test configuration replaces the OpenAI model with
`Scrawly.FakeAiModel`, so no test calls OpenAI.

## Deployment

A push to `main` deploys the app.

```mermaid
flowchart LR
  PUSH["Push to main"] --> CI["CI workflow<br>compile with warnings as errors,<br>build Hologram bundles, mix test"]
  CI -- "passes" --> DEPLOY["Fly Deploy workflow<br>flyctl deploy --remote-only"]
  CI -- "fails" --> STOP["No deploy"]
  DEPLOY --> BUILD["Docker build<br>mix assets.deploy and mix release"]
  BUILD --> MIGRATE["Release command bin/migrate<br>migrations and word sync"]
  MIGRATE --> RUN["bin/server on Fly.io"]
```

- `.github/workflows/test.yml` runs on every pull request and every push to
  `main`.
- `.github/workflows/fly-deploy.yml` runs only after CI passes on a push to
  `main`, and deploys the exact commit that CI tested. It needs the
  `FLY_API_TOKEN` repository secret.
- `fly.toml` gives a machine 1 GB of memory. The machine stops when idle and
  starts on the next request.

### Environment variables

`config/runtime.exs` reads these in production. Set secrets with
`fly secrets set NAME=value`.

| Variable | Required | Description |
|---|---|---|
| `DATABASE_URL` | Yes | PostgreSQL URL, for example `ecto://USER:PASS@HOST/DATABASE`. |
| `SECRET_KEY_BASE` | Yes | Signs and encrypts cookies. Generate one with `mix phx.gen.secret`. |
| `TOKEN_SIGNING_SECRET` | Yes | Signs the AshAuthentication tokens. |
| `PHX_HOST` | Yes | Public host name, for example `scrawly.fly.dev`. |
| `PORT` | No | HTTP port. Defaults to `4000`; `fly.toml` sets `8080`. |
| `PHX_SERVER` | No | Starts the web server. `bin/server` sets it. |
| `OPENAI_API_KEY` | No | Turns on AI word lists. Without it, AI rooms use the built-in list. |
| `OPENAI_ORG_ID` | No | OpenAI organization ID. |
| `POOL_SIZE` | No | Database pool size. Defaults to `10`. |
| `ECTO_IPV6` | No | Set to `true` to connect to the database over IPv6. |
| `CLIENT_IP_HEADER` | No | Header that holds the client's IP address for rate limits. Defaults to `fly-client-ip`. Set it to an empty string when no proxy overwrites the header. |
| `DNS_CLUSTER_QUERY` | No | DNS name for clustering nodes. |

> [!NOTE]
> Rooms, Realtime subscriptions, and the online count are node-local. Run one
> machine; more than one would need clustering.

## Further reading

- [Hologram documentation](https://hologram.page/docs). Hologram isn't Phoenix
  LiveView: it has its own templates, actions, and commands. `CLAUDE.md`
  summarizes its rules for this project.
- `REALTIME_MIGRATION_REPORT.md`: how the game moved from polling to Hologram
  Realtime, and why the live stroke stream stayed on a Phoenix channel.
- `notes/files/drawing-benchmarks.md` and `bench/README.md`: the drawing
  benchmarks, their budgets, and the rendering decisions.
- `priv/words/README.md`: how to add words and rate their difficulty.
