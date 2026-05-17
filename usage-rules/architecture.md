# Architecture

## Core Concepts

- Hologram apps are built from two building blocks: **Pages** (route-level entry points) and **Components** (reusable UI elements).
- State lives in the browser, not on the server. This enables immediate UI updates and reduces server load.
- Code execution is split into **Actions** (client-side, in-browser) and **Commands** (server-side, for DB/API access). Both can trigger each other.
- Hologram automatically determines which Elixir code runs on the client vs server and compiles the client portion to JavaScript. Do not manually manage this split.

## Do

- Think in terms of actions for UI logic and commands for server-side work (database, file system, external APIs).
- Let the framework handle client-server communication — it uses HTTP/2 persistent connections automatically.
- Rely on the virtual DOM for efficient updates; the framework manages it for you.
- Understand that the initial page is always server-rendered, then mounted and managed client-side.

## Don't

- Don't write manual HTTP endpoints or boilerplate for action-command communication.
- Don't assume WebSocket semantics — Hologram uses HTTP/2, which has no persistent connection overhead per user.
- Don't try to manually control which code is compiled to JS vs kept server-side; the framework handles code distribution.
- Don't treat Hologram like Phoenix LiveView — state is client-side, not server-side.
