# Scrawly - Fly.io Deployment Guide

## Cost Summary

| Component | Spec | Monthly Cost |
|-----------|------|-------------|
| Phoenix app | shared-cpu-1x, 512 MB RAM, 1 Machine | ~$3.19 |
| Postgres (unmanaged) | shared-cpu-1x, 1 GB RAM, 1 GB volume | ~$3.54 |
| Shared IPv4 | included | $0.00 |
| **Total** | | **~$6.73/month** |

With auto-stop enabled, the machine stops when idle and you only pay for storage. Real cost for light usage: **~$1-3/month**.

---

## Prerequisites

- [ ] `fly` CLI installed and authenticated (`fly auth whoami` to verify)
- [ ] OpenAI API key ready (used by LangChain for AI word generation)
- [ ] Git repo is clean and ready to deploy

---

## Step 0: Generate Release Files

Run the Phoenix release generator to create the Dockerfile and release scripts:

```bash
mix phx.gen.release --docker
```

This creates:

- `Dockerfile` -- multi-stage Docker build for the Phoenix release
- `rel/overlays/bin/server` -- starts the app with `PHX_SERVER=true`
- `rel/overlays/bin/migrate` -- runs Ecto migrations
- `.dockerignore` -- excludes dev/test files from the image

### 0a. Create a release module for migrations

Create `lib/scrawly/release.ex`:

```elixir
defmodule Scrawly.Release do
  @moduledoc """
  Tasks that can be run in production without Mix.
  """
  @app :scrawly

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
```

---

## Step 1: Add OpenAI Config to runtime.exs

The LangChain/OpenAI configuration currently only exists in `config/dev.exs`. Add it to `config/runtime.exs` inside the `if config_env() == :prod do` block so it works in production:

```elixir
# Add inside the `if config_env() == :prod do` block, after the token_signing_secret config:

# LangChain / OpenAI configuration for AI word generation
config :langchain, openai_key: System.get_env("OPENAI_API_KEY")
config :langchain, openai_org_id: System.get_env("OPENAI_ORG_ID")
```

> **Important**: Without this, AI word generation will not work in production.

---

## Step 2: Launch the Fly App

```bash
fly launch \
  --name scrawly \
  --region fra \
  --no-deploy \
  --org personal
```

- `fra` = Frankfurt -- pick whichever region is closest to you
- `--no-deploy` -- we need to set up the database first
- When prompted about databases, say **No** -- we create Postgres manually for the cheapest option

This generates `fly.toml`. Edit it to match:

```toml
app = "scrawly"
primary_region = "fra"
kill_signal = "SIGTERM"
kill_timeout = 120

[build]

[deploy]
  release_command = "/app/bin/migrate"

[env]
  PHX_HOST = "scrawly.fly.dev"
  PHX_SERVER = "true"
  DNS_CLUSTER_QUERY = "scrawly.internal"
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
    grace_period = "30s"
    interval = "30s"
    method = "GET"
    timeout = "5s"
    path = "/"

[[vm]]
  size = "shared-cpu-1x"
  memory = 512
```

Key settings:

- `min_machines_running = 0` + `auto_stop_machines = "stop"` -- machine stops when idle (saves money)
- `auto_start_machines = true` -- auto-start on incoming request (~2-5s cold start)
- `memory = 512` -- Scrawly is lighter than a full Ash/ChromicPDF app, 512 MB should suffice. Bump to 1024 if you see OOM kills.

---

## Step 3: Create the Postgres Database

```bash
fly postgres create \
  --name scrawly-db \
  --region fra \
  --vm-size shared-cpu-1x \
  --initial-cluster-size 1 \
  --volume-size 1
```

> **Save the credentials** -- Fly shows the password once.

### 3a. Attach the database to your app

```bash
fly postgres attach scrawly-db --app scrawly
```

This automatically sets `DATABASE_URL` as a secret on the `scrawly` app.

### 3b. Enable required PostgreSQL extensions

Connect to the database:

```bash
fly postgres connect --app scrawly-db
```

Then run:

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS citext;
\q
```

> **Pitfall**: If you skip this, migrations will fail with `type "citext" does not exist`. The Ash/AshPostgres migrations may also try to create an `ash-functions` extension -- the Fly Postgres user typically has the needed privileges. If it fails, grant superuser:
> ```sql
> ALTER USER scrawly WITH SUPERUSER;
> ```

---

## Step 4: Set Secrets

```bash
fly secrets set \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  TOKEN_SIGNING_SECRET=$(mix phx.gen.secret) \
  OPENAI_API_KEY="your-openai-api-key-here" \
  OPENAI_ORG_ID="your-openai-org-id-here" \
  --app scrawly
```

Replace `your-openai-api-key-here` and `your-openai-org-id-here` with your actual OpenAI credentials. `OPENAI_ORG_ID` is optional -- omit it if you don't use org-level billing.

`DATABASE_URL` was already set by `fly postgres attach`.

### Verify secrets

```bash
fly secrets list --app scrawly
```

You should see: `DATABASE_URL`, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`, `OPENAI_API_KEY` (and optionally `OPENAI_ORG_ID`).

---

## Step 5: Deploy

```bash
fly deploy --app scrawly
```

What happens:

1. Docker image builds (first build takes 5-10 min; subsequent builds use cache)
2. Image is pushed to Fly's registry
3. A temporary machine runs `/app/bin/migrate` (release command)
4. If migrations succeed, the app machine starts
5. Health check runs against `/`
6. Traffic is routed to the new machine

### Watch the logs

In a separate terminal:

```bash
fly logs --app scrawly
```

---

## Step 6: Seed the Database (Optional)

If you have seed data to load:

```bash
fly ssh console --app scrawly -C "/app/bin/scrawly eval 'Scrawly.Release.migrate()'"
```

Or to run a seeds file directly:

```bash
fly ssh console --app scrawly -C "/app/bin/scrawly eval 'Code.eval_file(\"priv/repo/seeds.exs\")'"
```

---

## Step 7: Verify

```bash
fly open --app scrawly
```

This opens `https://scrawly.fly.dev` in your browser. You should see the home page.

---

## Pitfalls and Solutions

### 1. Migration fails: extension does not exist

**Problem**: `ERROR: type "citext" does not exist` or similar.
**Cause**: PostgreSQL extensions not enabled before first deploy.
**Fix**: Run Step 3b before deploying.

### 2. Migration fails: permission denied to create extension

**Problem**: `ERROR: permission denied to create extension "ash-functions"`.
**Fix**: Connect to the DB and grant superuser:

```bash
fly postgres connect --app scrawly-db
```

```sql
ALTER USER scrawly WITH SUPERUSER;
\q
```

Then redeploy: `fly deploy --app scrawly`

### 3. AI word generation not working

**Problem**: Game doesn't generate words / LangChain errors in logs.
**Cause**: `OPENAI_API_KEY` not set, or the LangChain config is missing from `runtime.exs`.
**Fix**: Verify the secret is set (`fly secrets list --app scrawly`) and that you completed Step 1.

### 4. Health check fails / boot timeout

**Problem**: Machine starts but health check fails, causing restart loop.
**Fix**: Increase `grace_period` in fly.toml to `60s`. Check logs for startup errors.

### 5. Out of Memory (OOM) kills

**Problem**: Machine gets killed, logs show `SIGKILL`.
**Fix**: Scale up memory:

```bash
fly scale memory 1024 --app scrawly
```

### 6. Database connection refused

**Problem**: `(DBConnection.ConnectionError) connection refused`.
**Cause**: Postgres machine is stopped.
**Fix**:

```bash
fly machine start --app scrawly-db
```

### 7. IPv6 connection issues

**Problem**: Ecto can't reach Postgres.
**Fix**: Ensure these are set in fly.toml `[env]`:

- `ECTO_IPV6=true`
- `ERL_AFLAGS="-proto_dist inet6_tcp"`

### 8. Users get logged out on every deploy

**Problem**: Session cookies invalidated after deploy.
**Fix**: Set a persistent release cookie:

```bash
fly secrets set RELEASE_COOKIE=$(elixir -e ':crypto.strong_rand_bytes(40) |> Base.url_encode64() |> IO.puts()') --app scrawly
```

### 9. Docker build fails

**Problem**: Assets or dependencies fail to compile.
**Fix**: Rebuild without cache:

```bash
fly deploy --no-cache --app scrawly
```

---

## Quick Reference Commands

```bash
# View logs
fly logs --app scrawly

# SSH into the running machine
fly ssh console --app scrawly

# Open IEx remote shell
fly ssh console --app scrawly -C "/app/bin/scrawly remote"

# Scale memory
fly scale memory 1024 --app scrawly

# Restart the app
fly apps restart scrawly

# Check app status
fly status --app scrawly

# Check Postgres status
fly status --app scrawly-db

# Connect to Postgres directly
fly postgres connect --app scrawly-db

# View secrets
fly secrets list --app scrawly

# Redeploy
fly deploy --app scrawly
```

---

## Destroying When Done

To stop all charges:

```bash
fly apps destroy scrawly --yes
fly apps destroy scrawly-db --yes
```

This deletes machines, volumes, and all data. **Irreversible.**
