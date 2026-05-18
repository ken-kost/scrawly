# Scrawly Current Architecture

## System Overview

```
+------------------------------------------------------------------+
|                         Browser (Client)                          |
|                                                                   |
|  +--------------------------+  +-------------------------------+  |
|  |     Hologram Runtime     |  |       Virtual DOM              |  |
|  |  (Elixir compiled to JS) |  |  (Pages + Components)         |  |
|  |                          |  |                                |  |
|  |  Actions (client-side)   |  |  HomePage | GamePage           |  |
|  |  - put_state             |  |  GameScorePage | PastGamesPage |  |
|  |  - put_action (delay)    |  |  AppLayout (header)            |  |
|  |  - put_command (HTTP)    |  |                                |  |
|  |  - put_page (navigate)   |  |  Components:                  |  |
|  +--------------------------+  |  ChatBox | DrawingCanvas       |  |
|                                |  PlayerList | ScoreBoard       |  |
|                                |  RoomList                      |  |
|                                +-------------------------------+  |
+-------------------------------------|-----------------------------+
                                      | HTTP/2 (Commands)
                                      v
+------------------------------------------------------------------+
|                       Phoenix Server (Elixir)                     |
|                                                                   |
|  +---------------------------+  +------------------------------+  |
|  |   Hologram Command        |  |     RoomServer GenServer     |  |
|  |   Handlers (per request)  |  |     (one per room)           |  |
|  |                           |  |                              |  |
|  |  poll_room_state          |  |  State:                      |  |
|  |  join_room                |->|  - players, status, version  |  |
|  |  start_game               |  |  - game_id, round, drawer   |  |
|  |  send_chat_message        |  |  - current_word, time_left  |  |
|  |  send_drawing             |  |  - chat_messages             |  |
|  |  record_correct_guess     |  |  - drawing_path              |  |
|  |  clear_drawing            |  |  - correct_guessers          |  |
|  |  leave_room               |  |  - last_game_id              |  |
|  |  end_game                 |  |                              |  |
|  +---------------------------+  |  PubSub subscriber:          |  |
|                                 |  timer_update, round_ended   |  |
|                                 +--------|---------------------+  |
|                                          |                        |
|  +---------------------------+  +--------|---------------------+  |
|  |   RoundTimer GenServer    |  |     Ash Framework            |  |
|  |   (singleton)             |  |                              |  |
|  |                           |  |  Domains:                    |  |
|  |  80s countdown per game   |--+  - Games (Room, Game, Word,  |  |
|  |  Broadcasts every 1s via  |  |    GameResult)               |  |
|  |  Phoenix.PubSub           |  |  - Accounts (User, Token)    |  |
|  +---------------------------+  |                              |  |
|                                 |  Data Layer: AshPostgres     |  |
|  +---------------------------+  +--------|---------------------+  |
|  |  DynamicSupervisor        |           |                        |
|  |  + Registry               |           v                        |
|  |  (RoomServer lifecycle)   |  +------------------------------+  |
|  +---------------------------+  |     PostgreSQL Database       |  |
|                                 |  rooms, users, games, words,  |  |
|                                 |  game_results, tokens          |  |
|                                 +------------------------------+  |
+------------------------------------------------------------------+
```

---

## Data Flow: Polling Cycle

Both the home page and game page use the same non-blocking polling pattern:

```
  Client                          Server
    |                               |
    |  put_action(:poll_room,       |
    |    delay: 500)                |
    |                               |
    |  [500ms passes]               |
    |                               |
    |  action(:poll_room)           |
    |  --> put_command              |
    |      (:poll_room_state)       |
    |                               |
    |  --- HTTP POST ------------->  |
    |                               |  RoomServer.get_state(room_id)
    |                               |  Compute: is_drawer,
    |                               |    word_display, drawer_name
    |                               |  (WordHints runs server-side)
    |                               |
    |  <-- HTTP Response ---------- |
    |      put_action(:room_refreshed, state)
    |                               |
    |  action(:room_refreshed)      |
    |  --> put_state(...)           |
    |  --> put_action(:poll_room,   |
    |      delay: 500)              |
    |                               |
    |  [cycle repeats]              |
```

---

## Data Flow: Game Start

```
  Creator Client        Server              Joiner Client
      |                    |                      |
      | click Start Game   |                      |
      | --> command         |                      |
      |    (:start_game)   |                      |
      |                    |                      |
      | --- HTTP POST ---> |                      |
      |                    | Ash: create game,     |
      |                    |   start round, timer  |
      |                    |                      |
      |                    | RoomServer.start_game |
      |                    |   (bumps version,     |
      |                    |    resets scores)     |
      |                    |                      |
      | <-- HTTP (bare) -- |                      |
      |                    |                      |
      | [next poll_room]   |   [next poll_room]   |
      | --> HTTP --------> |  <------- HTTP <---- |
      |                    |                      |
      |  get_state returns |  get_state returns   |
      |  game_started=true |  game_started=true   |
      |  is_drawer=true    |  is_drawer=false     |
      |  word="butterfly"  |  word="butterfly"    |
      |  word_display=     |  word_display=       |
      |    "butterfly"     |    "_ _ _ _ _ _ _ _" |
      |                    |                      |
      | <-- room_refreshed |  room_refreshed -->  |
      | UI: show canvas,   |  UI: show canvas,   |
      |   word visible     |   hints visible      |
```

---

## Data Flow: Drawing Sync

```
  Drawer Client            Server              Viewer Client
      |                      |                      |
      | pointer_down(x,y)   |                      |
      | path = "M x y"      |                      |
      |                      |                      |
      | pointer_move(x,y)   |                      |
      | path += " L x y"    |                      |
      |   (accumulates      |                      |
      |    locally)          |                      |
      |                      |                      |
      | [50 chars unsent]    |                      |
      | send_drawing_delta() |                      |
      | --> command          |                      |
      |   (:send_drawing,    |                      |
      |    path_segment)     |                      |
      |                      |                      |
      | --- HTTP POST -----> |                      |
      |                      | RoomServer            |
      |                      |   .append_drawing     |
      |                      |   (bumps version)     |
      | <-- HTTP (bare) ---- |                      |
      |                      |                      |
      |                      | [viewer's next poll]  |
      |                      | <----- HTTP -------- |
      |                      | get_state: has full   |
      |                      |   drawing_path        |
      |                      | -------- HTTP ------> |
      |                      |                      |
      |                      |  room_refreshed:      |
      |                      |  sync_drawing_path    |
      |                      |  (viewer gets full    |
      |                      |   SVG path)           |
```

---

## Data Flow: Chat & Guessing

```
  Guesser Client           Server              Drawer Client
      |                      |                      |
      | types "butterfly"    |                      |
      | $input updates       |                      |
      |   new_message state  |                      |
      |                      |                      |
      | <form $submit>       |                      |
      | or click Send        |                      |
      |                      |                      |
      | action(:send_message)|                      |
      | guess_matches?       |                      |
      |   ("butterfly" ==    |                      |
      |    current_word)     |                      |
      |   --> YES! Correct!  |                      |
      |                      |                      |
      | --> command           |                      |
      | (:record_correct_    |                      |
      |  guess, points: 350) |                      |
      |                      |                      |
      | --- HTTP POST -----> |                      |
      |                      | Ash: update score    |
      |                      | RoomServer:           |
      |                      |  update_player_score  |
      |                      |  send_chat_message    |
      |                      |    ("X guessed!")     |
      |                      |  record_guess         |
      |                      |    (check all_guessed)|
      |                      |  if all_guessed:      |
      |                      |    stop_timer         |
      |                      |    schedule           |
      |                      |    auto_advance(3s)   |
      |                      |                      |
      | <-- HTTP (bare) ---- |                      |
      |                      |                      |
      | [both polls fire]    | [both polls fire]    |
      | see: chat msg,       | see: chat msg,       |
      |   score update,      |   score update,      |
      |   correct_guessers   |   correct_guessers   |
```

---

## Data Flow: Auto Round Advancement

```
  RoundTimer              RoomServer            Both Clients
      |                      |                      |
      | [80 seconds pass]    |                      |
      | {:round_ended,       |                      |
      |  reason: :time_up}   |                      |
      | --- PubSub --------> |                      |
      |                      | time_left: 0         |
      |                      | round_active: false   |
      |                      | add "Time's up!" msg  |
      |                      | bump version          |
      |                      |                      |
      |                      | Process.send_after    |
      |                      |   (:auto_advance, 3s) |
      |                      |                      |
      |                      | [3 seconds pass]     |
      |                      |                      |
      |                      | if round < total:     |
      |                      |   auto_next_round()  |
      |                      |   Ash: complete_round |
      |                      |   Ash: next_round     |
      |                      |   Ash: select_drawer  |
      |                      |   Ash: start_round    |
      |                      |   Ash: start_timer    |
      |                      |   clear drawing_path  |
      |                      |   add sys message     |
      |                      |                      |
      |                      | if round == total:    |
      |                      |   auto_end_game()    |
      |                      |   save_game_results  |
      |                      |   Ash: cleanup        |
      |                      |   set last_game_id    |
      |                      |                      |
      |                      | [polls detect change] |
      |                      | -----> redirect ----> |
      |                      |   to /game-results/   |
```

---

## Hologram Architecture

### How Hologram Works

```
+----------------------------------------------------------+
|                    Hologram Framework                      |
|                                                           |
|  Elixir Source Code                                       |
|       |                                                   |
|       +--> Server-side: init/3, commands                  |
|       |    (runs as normal Elixir on BEAM)                |
|       |                                                   |
|       +--> Client-side: actions, template                 |
|            (compiled to JavaScript, runs in browser)      |
|                                                           |
|  Key Constraint:                                          |
|  Actions run in browser -- can only use Hologram-safe     |
|  Elixir (no :erlang BIFs, no complex stdlib, no DB)      |
|                                                           |
|  Communication:                                           |
|  - put_action: schedules client-side action (with delay)  |
|  - put_command: sends HTTP POST to server                 |
|  - put_page: navigates to new page (new init cycle)       |
|  - put_state: updates component state (re-renders vDOM)   |
|                                                           |
|  NO server push. All updates must be client-initiated.    |
+----------------------------------------------------------+
```

### Ash Framework Integration

```
+----------------------------------------------------------+
|                     Ash Framework                          |
|                                                           |
|  Domains:                                                  |
|  +------------------+  +---------------------+            |
|  | Scrawly.Games    |  | Scrawly.Accounts    |            |
|  |                  |  |                     |            |
|  | Resources:       |  | Resources:          |            |
|  | - Room           |  | - User              |            |
|  | - Game           |  | - Token             |            |
|  | - Word           |  |                     |            |
|  | - GameResult     |  | Extensions:         |            |
|  |                  |  | - AshAuthentication |            |
|  | Code Interfaces: |  |   (magic link)      |            |
|  | - create_room    |  |                     |            |
|  | - join_room      |  | Code Interfaces:    |            |
|  | - start_game     |  | - create_user       |            |
|  | - create_game    |  | - join_room         |            |
|  | - start_round    |  | - leave_room        |            |
|  | - end_game       |  +---------------------+            |
|  | - save_results   |                                     |
|  +------------------+                                     |
|                                                           |
|  Data Layer: AshPostgres                                  |
|  Authorization: Ash.Policy.Authorizer (on User)           |
|  PubSub: Ash.Notifier.PubSub (on Room)                   |
+----------------------------------------------------------+
```

---

## Process Supervision Tree

```
Scrawly.Supervisor (one_for_one)
  |
  +-- ScrawlyWeb.Telemetry
  +-- Scrawly.Repo (Ecto/PostgreSQL)
  +-- DNSCluster
  +-- Phoenix.PubSub (name: Scrawly.PubSub)
  +-- Registry (name: Scrawly.RoomRegistry, keys: :unique)
  +-- DynamicSupervisor (name: Scrawly.RoomSupervisor)
  |     |
  |     +-- RoomServer (room_id: "abc-123")  [temporary]
  |     +-- RoomServer (room_id: "def-456")  [temporary]
  |     +-- ...
  |
  +-- ScrawlyWeb.Presence
  +-- Scrawly.Games.RoundTimer (singleton GenServer)
  +-- ScrawlyWeb.Endpoint (Bandit HTTP server)
  +-- AshAuthentication.Supervisor
```

---

## Database Schema

```
users
  id          UUID (PK)
  email       CI_STRING (unique)
  username    VARCHAR(2-20)
  score       INTEGER (default 0)
  player_state ENUM (connected, drawing, guessing, disconnected)
  current_room_id UUID (FK -> rooms.id, nullable)

rooms
  id          UUID (PK)
  name        VARCHAR (not null)
  code        VARCHAR(4-12) (unique)
  status      ENUM (lobby, playing, ended)
  max_players INTEGER (2-12, default 12)
  current_round INTEGER (default 0)
  creator_id  UUID (FK -> users.id, not null)

games
  id          UUID (PK)
  status      ENUM (in_progress, completed, cancelled)
  current_round INTEGER
  total_rounds INTEGER (1-10)
  current_word VARCHAR
  current_drawer_id UUID (FK -> users.id)
  room_id     UUID (FK -> rooms.id, not null)

words
  id          UUID (PK)
  text        VARCHAR(1-20)
  difficulty  ENUM (easy, medium, hard)

game_results
  id          UUID (PK)
  player_id   UUID (FK -> users.id)
  game_id     UUID (FK -> games.id)
  room_id     UUID (FK -> rooms.id)
  score       INTEGER (default 0)
  player_username VARCHAR
  created_at  TIMESTAMP

tokens (AshAuthentication)
  ...
```

---

## Page Routes

| Route | Page | Auth Required |
|-------|------|---------------|
| `/` | HomePage | No |
| `/game/:room_id` | GamePage | No (guest = Watcher) |
| `/game-results/:game_id` | GameScorePage | No |
| `/past-games` | PastGamesPage | Yes (shows empty for guests) |
| `/sign-in` | AshAuthentication LiveView | No |
| `/sign-out` | Phoenix Controller | Yes |
