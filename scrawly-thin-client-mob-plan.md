# Scrawly thin-client mob app — implementation plan

Goal: ship scrawly as an iOS/Android app where **the BEAM on device does
nothing but open a WebView and provide native bridges**. The Phoenix
server, Hologram pages, game state, Ash domain, AshAuthentication — all
of it stays on fly.io. The mobile app is essentially a hardened
WebView pointed at `https://scrawly.fly.dev/`, with `window.mob`
available for native interop.

Why this shape? Scrawly is a multiplayer game; shared state belongs on
a central server. Running per-device Phoenix + per-device game logic
would isolate every player from every other player. Thin client keeps
multiplayer working without a federation layer.

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  fly.io (scrawly.fly.dev)                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Scrawly.Application (full)                          │  │
│  │  • ScrawlyWeb.Endpoint (Phoenix + Hologram + Ash)    │  │
│  │  • Scrawly.Repo, AshAuthentication                   │  │
│  │  • Game servers: RoomSupervisor, RoundTimer,         │  │
│  │    DemoBoardServer, LobbyChatServer, Presence        │  │
│  │  • Channels: game:*, lobby:*, demo:board             │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
           ▲                          ▲
           │  HTTPS (Hologram pages,  │  WSS (Phoenix.Channels:
           │  assets, AshAuth)        │  game/lobby/demo)
           │                          │
┌──────────┴──────────────────────────┴──────────────────────┐
│  iPhone / Android phone                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Native mob shell (Swift / Kotlin)                   │  │
│  │  • Starts BEAM with -pa pointing at bundled beams    │  │
│  │  • Injects window.mob into the WebView (camera,      │  │
│  │    audio, sensors, storage, push, ...)               │  │
│  │  ┌─────────────────────────────────────────────────┐ │  │
│  │  │  BEAM (Scrawly.MobApp — minimal)                │ │  │
│  │  │  • Mob.Dist (for `mix mob.connect`)             │ │  │
│  │  │  • Mob.ComponentRegistry                        │ │  │
│  │  │  • Scrawly.MobScreen (one screen, one webview)  │ │  │
│  │  │  • No Phoenix endpoint                          │ │  │
│  │  │  • No Ecto, no Ash, no game servers             │ │  │
│  │  │  • No Hologram compilation                      │ │  │
│  │  └─────────────────────────────────────────────────┘ │  │
│  │  ┌─────────────────────────────────────────────────┐ │  │
│  │  │  WebView (WKWebView / Android WebView)          │ │  │
│  │  │  Loads https://scrawly.fly.dev/                 │ │  │
│  │  │  Renders Hologram pages directly                │ │  │
│  │  │  Channels: WSS to scrawly.fly.dev/socket        │ │  │
│  │  └─────────────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

The device BEAM is essentially a launcher for the WebView + a host for
mob's native bridges. It does not participate in scrawly's domain
logic at all.

---

## Phase 0 — Prerequisites

### 0.1 Deploy scrawly to fly.io

Scrawly already has [fly.toml](fly.toml) and [Dockerfile](Dockerfile);
fly app name is `scrawly` so the URL will be `https://scrawly.fly.dev`.

```bash
cd ~/scrawly
fly auth login                # one-time
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret) \
                DATABASE_URL=...                  # whatever your prod env needs
fly deploy
curl https://scrawly.fly.dev/                     # should return the home page HTML
```

### 0.2 Make sure prod is WebView-friendly

Verify these in [config/runtime.exs](config/runtime.exs) for `:prod`:

- `url: [host: "scrawly.fly.dev", port: 443, scheme: "https"]` ✓ (already there per a quick grep)
- `check_origin` either unset (Phoenix defaults to the configured `url`
  host, which matches the WebView's origin) or explicitly
  `["https://scrawly.fly.dev"]`. Don't set `check_origin: false` in
  prod — WebView origin matches the page origin, so the default works.
- WebSocket origin policy: same as `check_origin`. Phoenix's
  `socket "/socket"` mount honours `check_origin` unless overridden.
- Cookie `same_site: "Lax"` (already set). WebViews retain cookies
  scoped to the loaded domain, so AshAuth's session works without
  bridge gymnastics.

### 0.3 Verify the deployed site from a real WebView

Before touching mobile code, sanity check:

1. Open https://scrawly.fly.dev/ in Safari on iOS / Chrome on Android
2. Verify Hologram home page renders
3. Sign in (AshAuthentication flow)
4. Join a game room, verify channels work (WebSocket connects, presence
   shows you, draws sync between two physical devices on the same room)

If any of this is broken in a normal mobile browser, mob won't fix
it — it's a server-side issue. Address before continuing.

---

## Phase 1 — Strip the current `mob.install` output back to thin-client shape

Running `mix mob.install` from `mob_new` already gave you:

| File | What it generated | What we want |
|---|---|---|
| [lib/scrawly/mob_app.ex](lib/scrawly/mob_app.ex) | LiveView-flavoured entry that starts Phoenix on device | **Rewrite** to thin entry |
| [lib/scrawly/mob_screen.ex](lib/scrawly/mob_screen.ex) | `MOB_HOST_URL` env-driven WebView | **Edit** default URL to fly.io |
| [lib/scrawly/application.ex](lib/scrawly/application.ex) | `Mob.App` added to children | **Remove** — server doesn't need it |
| [src/scrawly.erl](src/scrawly.erl) | Erlang bootstrap | **Keep** unchanged |
| [mix.exs](mix.exs) | `:mob`, `:mob_dev` deps + `erlc_paths` | **Keep** |
| [mob.exs](mob.exs) | Build env config | **Keep**, edit paths for your machine |
| [android/](android/), [ios/](ios/) | Native trees | **Keep** |
| [.gitignore](.gitignore) | `mob.exs` ignored | **Keep** |

### 1.1 Rewrite `lib/scrawly/mob_app.ex`

Replace the LV-flavoured contents with a native-style entry point that
uses `use Mob.App` and explicitly does **not** start `:scrawly` (which
would boot Phoenix, Repo, game servers, etc.). This mirrors what
`mix mob.new` (native, non-LiveView mode) generates, minus Ecto since
we have no on-device database.

```elixir
defmodule Scrawly.MobApp do
  @moduledoc """
  On-device BEAM entry — thin client for the deployed Scrawly server.

  Does NOT start `:scrawly` as an OTP application: the host's
  `Scrawly.Application` brings up Phoenix + Hologram + Ash + game
  servers, all of which belong on the deployed fly.io node, not on
  the phone. This module is invoked from `src/scrawly.erl` (the
  Erlang bootstrap called by Mob's native shell).
  """

  use Mob.App

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: Scrawly.MobScreen)
  end

  @impl Mob.App
  def on_start do
    # Configure pure-BEAM DNS so Req/Finch/`:gen_tcp` work without
    # iOS's broken `:inet_gethost` port program. Same pattern as
    # `mob_new`'s native template.
    Mob.DNS.configure_pure_beam()

    # Open the WebView pointing at the deployed Phoenix server.
    Mob.Screen.start_root(Scrawly.MobScreen)

    # Erlang distribution for `mix mob.connect` (Mac-side IEx). Optional.
    Mob.Dist.ensure_started(
      node: :"scrawly_android@127.0.0.1",
      cookie: :mob_secret
    )
  end
end
```

Note: name stays `Scrawly.MobApp` so [src/scrawly.erl](src/scrawly.erl)
doesn't need to change. If you want to align with `mix mob.new`'s
native naming (`Scrawly.App`), rename here and in the .erl entry.

### 1.2 Edit `lib/scrawly/mob_screen.ex`

The installed version defaults to `http://127.0.0.1:4000/`. Change the
default to your fly.io URL so the device build works without an env
var:

```elixir
def host_url do
  System.get_env("MOB_HOST_URL", "https://scrawly.fly.dev/")
end
```

Keep `MOB_HOST_URL` as an override so you can point at a local Phoenix
during development (`MOB_HOST_URL=http://10.0.0.5:4123/` for an
emulator hitting your Mac's IP, etc.).

### 1.3 Remove `Mob.App` from `Scrawly.Application`'s children

Open [lib/scrawly/application.ex](lib/scrawly/application.ex) and
delete the `Mob.App` line that `mix mob.install` added after
`ScrawlyWeb.Endpoint`. The server doesn't need it — `Mob.App` is the
on-device runtime, and starting it inside the fly.io container would
either crash (no WebView available) or do nothing useful.

If you ever want this conditional rather than removed, you can gate
it on `Mix.target()`:

```elixir
children =
  base_children() ++
    if Mix.target() == :host, do: [], else: [Scrawly.MobApp]
```

But the cleaner thing is: device builds use `Scrawly.MobApp` as the
OTP application module via the Erlang bootstrap, not via
`Scrawly.Application`. So just remove the entry.

### 1.4 (Optional) point the OTP application module conditionally

In [mix.exs](mix.exs), `application/0` returns `mod: {Scrawly.Application, []}`.
That's fine for the server build. For the device build, **the
Erlang bootstrap calls `Scrawly.MobApp.start/0` directly** before
the OTP `:scrawly` application would normally start, so the `mod:`
setting effectively doesn't apply on-device. Leave mix.exs alone.

(If you later find the OTP application *is* auto-starting on-device
and clobbering your thin setup, gate `mod:` on `Mix.target()`. Cross
that bridge if you hit it.)

### 1.5 Verify mob.exs

Edit [mob.exs](mob.exs) for your machine — set `mob_dir` to your
local `mob` checkout and `elixir_lib` to your installed Elixir's
lib directory. The installer pre-fills sensible defaults; you may
not need to edit it.

---

## Phase 2 — Test the device build locally

### 2.1 Set Android SDK path

```bash
# android/local.properties (gitignored by default)
sdk.dir=/Users/you/Library/Android/sdk        # macOS
# or
sdk.dir=/home/you/Android/Sdk                 # Linux
```

### 2.2 First-time setup

```bash
cd ~/scrawly
mix deps.get
mix mob.install          # different task — from mob_dev. Icon gen + signing setup.
                         # (Naming collision with our installer; mob_dev's wins
                         # here since we removed the mob_new archive.)
```

### 2.3 Deploy to a connected emulator/device

```bash
# Android (emulator must be running, or device connected via adb)
mix mob.deploy --native

# iOS (simulator or physical device — physical needs `mix mob.provision` once)
MOB_TARGET=ios mix mob.deploy --native
```

First deploy compiles the native shell, packages the BEAM + your
.beam files, signs the APK / .app, and installs to the device. Takes
several minutes.

### 2.4 Smoke test

1. Launch the app on the device
2. WebView should load https://scrawly.fly.dev/
3. Hologram home page renders
4. Tap "log in" → AshAuth flow works (cookies set, session persists)
5. Join a lobby → presence + chat works (WebSocket connects)
6. Start a game → drawing + guessing syncs across devices

If 2 fails: check device internet, check fly app is up
(`fly status`), check the WebView console (Safari Web Inspector for
iOS, `chrome://inspect` for Android Chrome).

If 3-6 work in mobile Safari/Chrome but fail in the mob WebView:
likely an origin or cookie policy issue. The mob WebView's user-agent
differs from Safari/Chrome — verify server-side that you don't have
UA-based filtering somewhere.

### 2.5 Verify native bridge works

In the device's WebView devtools console:

```javascript
typeof window.mob              // "object" — injected by Mob's native shell
window.mob.send                // function — sends to native
```

For now `window.mob.send` calls go nowhere useful (we removed the
channels bridge that routed them back to BEAM). To wire up an actual
native feature, see Phase 4 below.

---

## Phase 3 — Day-to-day workflow once it works

```bash
mix mob.deploy             # fast: push changed BEAMs, restart on device
mix mob.watch              # auto-deploy on file save
mix mob.connect            # IEx attached to device BEAM
```

Most scrawly work happens server-side (Hologram pages, channels, Ash
domain) and reaches the device via the next page load — no
redeploy needed for server-only changes. Redeploy is only required
when you edit:

- `lib/scrawly/mob_app.ex` (thin entry)
- `lib/scrawly/mob_screen.ex` (WebView config)
- Anything under `android/` or `ios/`

After a server-side change: `fly deploy` from scrawly, then refresh
the WebView (the app's reload button or kill+relaunch).

---

## Phase 4 — Native features (when you need them)

The thin-client BEAM doesn't process channel messages, so any
JS→native calls go directly through `window.mob` — which is injected
by [MobBridge.kt](android/app/src/main/java/MobBridge.kt) /
the iOS equivalent — into native code. The native code can either:

(a) Return a result directly to JS via `window.mob._dispatch(...)`, or
(b) Send the result to the deployed Phoenix server via an HTTP request
    or by using the WebView's existing channel connection.

For example, to add "take a photo" for a game avatar:

1. In the Hologram page, JS code calls
   `window.mob.send({op: "take_photo"})`.
2. `MobBridge.kt` matches `take_photo`, launches the camera intent.
3. Camera returns an image. Native code base64-encodes it.
4. Native code calls `window.mob._dispatch(JSON.stringify({op: "photo_taken", data: "..."}))`.
5. JS handler uploads via channel or HTTP to your Phoenix endpoint.

The native code lives in Kotlin/Swift — not in the thin BEAM. Adding
new bridge ops means editing `android/app/src/main/java/MobBridge.kt`
and the iOS counterpart. The BEAM is not involved.

If you find you need a lot of BEAM-side logic for native features
(e.g. complex permission flows, encryption, on-device caching), the
thin client may not be the right architecture anymore. At that
point: either move some logic to the deployed server (which the
WebView can hit normally), or revisit the on-device-BEAM-with-
federation approach.

---

## What you intentionally don't touch

- **Server-side `Scrawly.Application` children** — Phoenix, Repo,
  AshAuthSupervisor, RoomSupervisor, RoundTimer, DemoBoardServer,
  LobbyChatServer, Presence. All keep running on fly.io.
- **Hologram pages** — they're served from fly.io, rendered in the
  WebView. No on-device Hologram compilation.
- **Channels** — `game:*`, `lobby:*`, `demo:board`. The WebView's JS
  joins them over WSS to scrawly.fly.dev. The on-device BEAM never
  sees these channels.
- **Ash domain, AshAuthentication** — server-only. Tokens travel
  via cookies set on scrawly.fly.dev.
- **esbuild / Tailwind** — compiled server-side as part of the fly
  deploy. The device build doesn't run them.

---

## Open questions to resolve as you go

1. **Push notifications.** If you want them, this is *one* place where
   the on-device BEAM has to do real work (register a device token
   with APNs/FCM, deliver foreground notifications). Add to
   `Scrawly.MobApp.on_start/0` later if needed.
2. **Offline behaviour.** Currently the app does nothing useful when
   the network is gone (WebView shows error page). If you want a
   "lost connection" screen, render it from a second `Mob.Screen`
   triggered by network status changes (mob has APIs for this).
3. **Deep links.** Tapping `scrawly://game/abc123` should open the
   game directly. Configure URL schemes in `Info.plist` /
   `AndroidManifest.xml`; the WebView can intercept and route.
4. **Auth on first launch.** When the user opens the app for the
   first time, the WebView loads the home page (unauthenticated).
   They sign in via the normal AshAuth flow. Cookies persist for
   subsequent launches. No special bridge code needed.
5. **App Store / Play Store submission.** Requires app icons,
   screenshots, privacy policy, developer accounts. Out of scope for
   "make it work locally."

---

## Verification checklist

Before declaring victory:

- [ ] `fly deploy` succeeds and `https://scrawly.fly.dev/` loads in a
      desktop browser
- [ ] Hologram pages render, AshAuth sign-in works, channels join
      (test in mobile Safari/Chrome first — easier to debug than the
      WebView)
- [ ] `mix mob.deploy --native` builds and installs to an Android
      emulator
- [ ] The mob app launches, the WebView loads scrawly.fly.dev, you can
      sign in and start a game
- [ ] Force-quit and relaunch — session persists (cookies retained)
- [ ] Two devices in the same game room see each other's strokes in
      real time (proves channels work from the WebView)
- [ ] `mix mob.deploy --native` for iOS sim works the same way
- [ ] (Optional) iOS physical device works after `mix mob.provision`
