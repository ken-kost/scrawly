# Ciris - Fly.io Deployment Guide

## Cost Summary

| Component | Spec | Monthly Cost |
|-----------|------|-------------|
| Phoenix app | shared-cpu-1x, 1 GB RAM, 1 Machine | ~$5.92 |
| Postgres (unmanaged) | shared-cpu-1x, 1 GB RAM, 3 GB volume | ~$5.42 |
| Shared IPv4 | included | $0.00 |
| **Total** | | **~$11.34/month** |

Why 1 GB RAM: Ciris has 17 Ash domains, Oban workers, ChromicPDF (Chromium subprocess), LiveView connections. 512 MB will OOM. 256 MB is not viable.

Auto-stop is enabled -- when nobody is using the app, the machine stops and you only pay for storage (~$0.45/month for the volume). Real cost will be much less than $11/month if usage is intermittent.

---

## Prerequisites

- [x] `fly` CLI installed and authenticated (`fly auth whoami` to verify)
- [ ] PostgreSQL extensions your app needs: `uuid-ossp`, `citext`, `pg_trgm`, `btree_gist` (handled below)

---

## Step 0: Create Missing Release Files -- DONE

Already implemented. Files created:

- `lib/ciris/release.ex` -- migrate + seed release tasks (runs `seeds.exs` then `ciris-data.exs`)
- `rel/overlays/bin/migrate` -- migration script (used by `release_command` on deploy)
- `rel/overlays/bin/seed` -- seed script (run manually via `fly ssh console --app ciris -C "/app/bin/seed"`)
- `rel/env.sh.eex` -- Erlang IPv6 node naming for Fly.io networking

---

## Step 1: Install ChromicPDF Dependencies in Dockerfile -- DONE

Already applied. Changes made to `Dockerfile`:

- Added `chromium` to runner stage `apt-get install`
- Added `ENV CHROMIC_PDF_CHROME_EXECUTABLE="/usr/bin/chromium"` after locale setup
```

> **Pitfall**: Without Chromium, ChromicPDF will crash on startup with `enoent`. The app will boot-loop.
> If you want to skip PDF generation for the demo, you can instead wrap ChromicPDF in Application.ex with a conditional (see Pitfalls section).

---

## Step 2: Launch the Fly App

```bash
fly launch \
  --name ciris \
  --region fra \
  --no-deploy \
  --org personal
```

- `fra` = Frankfurt, Germany -- closest region to Croatia
- `--no-deploy` -- we need to set up the database first
- When prompted "Would you like to copy its configuration to the new app?" say **Yes** if it detects your Dockerfile
- When prompted about databases, say **No** -- we'll create Postgres manually for the cheapest option

This creates `fly.toml`. Edit it to match:

```toml
app = "ciris"
primary_region = "fra"
kill_signal = "SIGTERM"
kill_timeout = 120

[build]

[deploy]
  release_command = "/app/bin/migrate"

[env]
  PHX_HOST = "ciris.fly.dev"
  DNS_CLUSTER_QUERY = "ciris.internal"
  ECTO_IPV6 = "true"
  ERL_AFLAGS = "-proto_dist inet6_tcp"
  PORT = "4000"

[http_service]
  internal_port = 4000
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0

  [http_service.concurrency]
    type = "connections"
    soft_limit = 200
    hard_limit = 250

  [[http_service.checks]]
    grace_period = "60s"
    interval = "30s"
    method = "GET"
    timeout = "5s"
    path = "/users/sign-in"

[[vm]]
  size = "shared-cpu-1x"
  memory = 1024
```

Key settings:
- `min_machines_running = 0` -- machine stops when idle (saves money!)
- `auto_stop_machines = "stop"` -- auto-stop on zero connections
- `auto_start_machines = true` -- auto-start on incoming request (~2-5s cold start)
- `grace_period = "60s"` -- give the BEAM + ChromicPDF time to boot
- Health check path `/users/sign-in` -- the login page, always accessible
- `memory = 1024` -- 1 GB, enough for the BEAM + ChromicPDF

---

## Step 3: Create the Postgres Database

```bash
fly postgres create \
  --name ciris-db \
  --region fra \
  --vm-size shared-cpu-1x \
  --initial-cluster-size 1 \
  --volume-size 3
```

This creates an unmanaged Postgres app. Cost: ~$5.42/month (can be less with auto-stop).

> **Note**: Fly will output the connection credentials. Save them -- you won't see the password again.

### 3a. Attach the database to your app

```bash
fly postgres attach ciris-db --app ciris
```

This automatically sets the `DATABASE_URL` secret on your `ciris` app.

### 3b. Enable required PostgreSQL extensions

Connect to the database:

```bash
fly postgres connect --app ciris-db
```

Then run:

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
\q
```

> **Pitfall**: If you skip this, the first migration will fail with `ERROR: type "citext" does not exist` or similar. The `release_command` will fail and the deploy will abort.

> **Pitfall**: The `ash-functions` extension is custom to your dev setup (created by AshPostgres migrations). The migration that creates it (`CREATE EXTENSION IF NOT EXISTS "ash-functions"`) should run automatically as part of your Ecto migrations. If it fails, check that the Postgres user has `SUPERUSER` or `CREATE` privileges on the database. The Fly-managed Postgres user typically does.

---

## Step 4: Set Secrets

```bash
fly secrets set \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  TOKEN_SIGNING_SECRET=$(mix phx.gen.secret) \
  --app ciris
```

`DATABASE_URL` was already set by `fly postgres attach`.

Verify:

```bash
fly secrets list --app ciris
```

You should see: `DATABASE_URL`, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`.

---

## Step 5: Deploy

```bash
fly deploy --app ciris
```

What happens:
1. Docker image builds (first build takes 5-10 min; subsequent builds use cache)
2. Image is pushed to Fly's registry
3. A temporary machine runs `/app/bin/migrate` (your release command)
4. If migrations succeed, the app machine starts
5. Health check runs against `/users/sign-in`
6. Traffic is routed to the new machine

### Watch the logs

In a separate terminal:

```bash
fly logs --app ciris
```

---

## Step 6: Seed the Database

After the first deploy succeeds, seed reference data + the demo organization:

```bash
fly ssh console --app ciris -C "/app/bin/seed"
```

This runs `seeds.exs` (currencies, municipalities, per-diem rates, etc.) then `ciris-data.exs` (TEST d.o.o. organization, chart of accounts, admin user).

Login credentials after seeding:
- **Admin**: `admin@test-doo.hr` / `Ciris!2026`

> **Pitfall**: If seeding fails with a mailer error, it should be handled (the seed script suppresses the mailer). If it fails for other reasons, you can SSH in and debug:
> ```bash
> fly ssh console --app ciris -C "/app/bin/ciris remote"
> ```

---

## Step 7: Verify

```bash
fly open --app ciris
```

This opens `https://ciris.fly.dev` in your browser. You should see the login page.

---

## Cost Optimization Tips

### Use auto-stop (already configured above)

With `min_machines_running = 0` and `auto_stop_machines = "stop"`, the app machine stops when idle. You only pay for:
- Storage: ~$0.45/month (3 GB volume for Postgres)
- Compute: only while someone is actively using the app

For a demo that gets a few visits per day, real cost could be **$2-4/month** instead of $11.

### Scale down Postgres if needed

If 3 GB is too much storage:

```bash
# Can't shrink volumes, but can recreate with 1 GB
fly postgres create --name ciris-db-small --region fra --vm-size shared-cpu-1x --volume-size 1 --initial-cluster-size 1
```

### Monitor costs

```bash
fly billing --app ciris
```

---

## Pitfalls and Solutions

### 1. ChromicPDF crashes on boot

**Problem**: `(ErlangError) Erlang error: :enoent` from ChromicPDF.
**Cause**: Chromium not installed in Docker runner image.
**Fix**: Add `chromium` to the runner's `apt-get install` (Step 1).
**Alternative**: If you don't need PDFs for the demo, conditionally start ChromicPDF:

```elixir
# In lib/ciris/application.ex, replace:
ChromicPDF,
# With:
if System.get_env("ENABLE_PDF") == "true", do: ChromicPDF, else: nil,
# Then add |> Enum.reject(&is_nil/1) before passing to Supervisor
```

### 2. Migration fails: extension does not exist

**Problem**: `ERROR: type "citext" does not exist` or `extension "pg_trgm" is not available`.
**Cause**: PostgreSQL extensions not enabled before running migrations.
**Fix**: Run Step 3b (CREATE EXTENSION commands) before first deploy.

### 3. Migration fails: permission denied to create extension

**Problem**: `ERROR: permission denied to create extension "ash-functions"`.
**Cause**: The AshPostgres installer migration tries to create extensions. Fly Postgres user might not have SUPERUSER.
**Fix**: Connect manually and create it:

```bash
fly postgres connect --app ciris-db
```
```sql
-- The ash-functions extension is created by AshPostgres migrations
-- If it fails, grant superuser to the app's DB user:
ALTER USER ciris WITH SUPERUSER;
\q
```

Then re-deploy: `fly deploy --app ciris`

### 4. Health check fails / boot timeout

**Problem**: Machine starts but health check at `/` fails, causing restart loop.
**Cause**: The app takes too long to boot (ChromicPDF downloading Chromium, compiling code, etc.)
**Fix**: Increase `grace_period` in fly.toml to `90s` or `120s`. Use a known-good health check path like `/users/sign-in`.

### 5. Out of Memory (OOM) kills

**Problem**: Machine gets killed repeatedly, logs show `SIGKILL`.
**Cause**: 512 MB or less is not enough for BEAM + ChromicPDF + 17 Ash domains.
**Fix**: Scale up memory:

```bash
fly scale memory 1024 --app ciris
```

### 6. Database connection refused

**Problem**: `(DBConnection.ConnectionError) connection refused`.
**Cause**: Postgres machine is stopped (auto-stop) or hasn't started yet.
**Fix**: Fly Postgres doesn't auto-stop by default, but if you enabled it:

```bash
fly machine start --app ciris-db
```

Or disable auto-stop on the DB app:

```bash
fly scale count 1 --app ciris-db
```

### 7. IPv6 connection issues

**Problem**: BEAM nodes can't connect, or Ecto can't reach Postgres.
**Cause**: Missing IPv6 configuration.
**Fix**: Ensure these are set:
- `ECTO_IPV6=true` in fly.toml `[env]`
- `ERL_AFLAGS="-proto_dist inet6_tcp"` in fly.toml `[env]` and `rel/env.sh.eex`

### 8. Cookie/session signing changes on every deploy

**Problem**: Users get logged out on every deploy.
**Cause**: Release cookie changes.
**Fix**: Set a persistent cookie:

```bash
fly secrets set RELEASE_COOKIE=$(elixir -e ':crypto.strong_rand_bytes(40) |> Base.url_encode64() |> IO.puts()') --app ciris
```

### 9. Docker build fails: assets.setup or assets.deploy

**Problem**: `** (Mix) Could not find an Elixir compiler...` or esbuild/tailwind not found.
**Cause**: The `mix assets.setup` step in the Dockerfile downloads esbuild and tailwind. If the Docker build cache is stale or network fails, it breaks.
**Fix**: Rebuild without cache:

```bash
fly deploy --no-cache --app ciris
```

### 10. Oban jobs run on every machine

**Problem**: If you scale to 2+ machines, Oban jobs might duplicate.
**Cause**: Oban uses `Oban.Notifiers.Postgres` (your config) which handles this correctly via database locks.
**Fix**: No fix needed -- Oban with Postgres notifier is multi-node safe.

### 11. force_ssl redirect loop

**Problem**: Infinite redirect when accessing the app.
**Cause**: `force_ssl` in `prod.exs` + Fly's proxy setup.
**Fix**: Your `prod.exs` already has `rewrite_on: [:x_forwarded_proto]` and excludes localhost. This should work with Fly's proxy. If it doesn't, temporarily comment out force_ssl to debug.

---

## Quick Reference Commands

```bash
# View logs
fly logs --app ciris

# SSH into the running machine
fly ssh console --app ciris

# Open IEx remote shell
fly ssh console --app ciris -C "/app/bin/ciris remote"

# Scale memory
fly scale memory 1024 --app ciris

# Restart the app
fly apps restart ciris

# Check app status
fly status --app ciris

# Check Postgres status
fly status --app ciris-db

# Connect to Postgres directly
fly postgres connect --app ciris-db

# View secrets
fly secrets list --app ciris

# Destroy everything when done (stops all billing)
fly apps destroy ciris
fly apps destroy ciris-db
```

---

## Destroying When Done

When the demo period is over, destroy both apps to stop all charges:

```bash
fly apps destroy ciris --yes
fly apps destroy ciris-db --yes
```

This deletes machines, volumes, and all data. **Irreversible.**
