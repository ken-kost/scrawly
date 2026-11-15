#!/usr/bin/env bash
# A local production build of Scrawly for the client benchmark
# (bench/drawing_client.mjs): a `mix release` built from this working tree in
# a scratch folder, served on a spare port against a scratch database. It
# never touches the dev build (_build/dev), the dev database or production.
#
#   bench/prod_server.sh build   copy the tree to $BENCH_DIR/src, build the release
#   bench/prod_server.sh start   create + migrate the scratch DB, start on $BENCH_PORT
#   bench/prod_server.sh stop    stop the release
#   bench/prod_server.sh drop    drop the scratch DB
#   bench/prod_server.sh clean   stop, drop, and delete $BENCH_DIR
#   bench/prod_server.sh rpc EXPR    evaluate Elixir on the running release
#   bench/prod_server.sh bundles     print the Hologram bundle sizes (JSON)
#
# Settings (environment):
#   BENCH_DIR      scratch folder (default /tmp/scrawly-bench)
#   BENCH_PORT     HTTP port (default 4100)
#   BENCH_DB       scratch database name (default scrawly_bench)
#   BENCH_PG       postgres URL without the database (default
#                  ecto://postgres:postgres@localhost)
#   BENCH_SEED     optional folder holding deps/ and _build/ of an earlier
#                  prod build, copied once to skip the dependency build
#
# Needs the project's toolchain (Elixir 1.19 / OTP 28, see the Dockerfile) on
# PATH, psql/createdb/dropdb, and network access the first time (deps, the
# esbuild/tailwind binaries, Hologram's npm install).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="${BENCH_DIR:-/tmp/scrawly-bench}"
BENCH_PORT="${BENCH_PORT:-4100}"
BENCH_DB="${BENCH_DB:-scrawly_bench}"
BENCH_PG="${BENCH_PG:-ecto://postgres:postgres@localhost}"
SRC="$BENCH_DIR/src"
REL="$SRC/_build/prod/rel/scrawly"

# psql connection pieces from BENCH_PG (ecto://user:pass@host[:port])
pg_rest="${BENCH_PG#ecto://}"
PGUSER="${pg_rest%%:*}"
pg_rest="${pg_rest#*:}"
PGPASSWORD="${pg_rest%%@*}"
pg_hostport="${pg_rest#*@}"
PGHOST="${pg_hostport%%:*}"
PGPORT="5432"
[[ "$pg_hostport" == *:* ]] && PGPORT="${pg_hostport##*:}"
export PGUSER PGPASSWORD PGHOST PGPORT

release_env() {
  mkdir -p "$BENCH_DIR"
  # Throwaway secrets, made once per scratch folder.
  if [[ ! -f "$BENCH_DIR/secrets" ]]; then
    {
      echo "SECRET_KEY_BASE=$(od -An -tx1 -N48 /dev/urandom | tr -d ' \n')"
      echo "TOKEN_SIGNING_SECRET=$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
      echo "RELEASE_COOKIE=bench$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    } > "$BENCH_DIR/secrets"
  fi
  set -a
  # shellcheck disable=SC1091
  source "$BENCH_DIR/secrets"
  set +a
  export DATABASE_URL="$BENCH_PG/$BENCH_DB"
  export PHX_HOST=localhost PORT="$BENCH_PORT" PHX_SERVER=true POOL_SIZE=10
  # No proxy in front: per-client limits use the peer address.
  export CLIENT_IP_HEADER=""
  export RELEASE_NODE="scrawly_bench_${BENCH_PORT}@127.0.0.1" RELEASE_DISTRIBUTION=name
  # Without these Hologram.env() is :dev, Hologram stays off and pages 404.
  export MIX_ENV=prod HOLOGRAM_ENV=prod
  export ELIXIR_ERL_OPTIONS="+fnu" LANG=C.UTF-8
}

cmd_build() {
  mkdir -p "$SRC"
  if [[ -n "${BENCH_SEED:-}" && ! -d "$SRC/deps" ]]; then
    echo "seeding deps/ and _build/ from $BENCH_SEED"
    cp -a "$BENCH_SEED/deps" "$SRC/"
    mkdir -p "$SRC/_build"
    cp -a "$BENCH_SEED/_build/." "$SRC/_build/"
  fi
  # The tree as git sees it (tracked and untracked, minus .gitignore'd
  # build output), without the parts a release doesn't use.
  # The explicit build-output excludes protect the receiver's own deps/ and
  # _build/ from --delete (its .gitignore rules alone do not).
  rsync -a --delete \
    --exclude=/deps/ --exclude=/_build/ --exclude=/assets/node_modules/ \
    --filter=':- .gitignore' \
    --exclude=/.git --exclude=/.claude --exclude=/android --exclude=/designs \
    --exclude=/notes --exclude=/bench --exclude=/test --exclude=/.elixir_ls \
    --exclude='*.apk' --exclude=erl_crash.dump \
    "$ROOT/" "$SRC/"
  cd "$SRC"
  export MIX_ENV=prod
  mix deps.get --only prod
  mix compile
  mix assets.deploy
  mix release --overwrite
  echo "built $REL"
}

cmd_start() {
  release_env
  [[ -x "$REL/bin/scrawly" ]] || { echo "no release at $REL: run '$0 build' first" >&2; exit 1; }
  if ! psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$BENCH_DB'" | grep -q 1; then
    createdb "$BENCH_DB"
    echo "created database $BENCH_DB"
  fi
  "$REL/bin/migrate" > "$BENCH_DIR/migrate.log" 2>&1 || { cat "$BENCH_DIR/migrate.log"; exit 1; }
  if "$REL/bin/scrawly" pid > /dev/null 2>&1; then
    echo "already running on :$BENCH_PORT"
    return
  fi
  "$REL/bin/scrawly" daemon
  for _ in $(seq 1 60); do
    if curl -fs -o /dev/null "http://localhost:$BENCH_PORT/"; then
      echo "prod release up on http://localhost:$BENCH_PORT (db $BENCH_DB)"
      return
    fi
    sleep 1
  done
  echo "the release did not answer on :$BENCH_PORT" >&2
  exit 1
}

cmd_stop() {
  release_env
  if [[ -x "$REL/bin/scrawly" ]] && "$REL/bin/scrawly" pid > /dev/null 2>&1; then
    "$REL/bin/scrawly" stop
    echo "stopped"
  else
    echo "not running"
  fi
}

cmd_drop() {
  dropdb --if-exists "$BENCH_DB"
  echo "dropped database $BENCH_DB (if it existed)"
}

cmd_rpc() {
  release_env
  "$REL/bin/scrawly" rpc "$1"
}

# Hologram's bundles in the release, against config :hologram max_bundle_size.
cmd_bundles() {
  local dir
  dir="$(ls -d "$REL"/lib/hologram-*/priv/static 2>/dev/null | head -1)"
  [[ -n "$dir" ]] || { echo "no release bundles under $REL" >&2; exit 1; }
  local first=1
  echo "{"
  for f in "$dir"/runtime-*.js "$dir"/page-*.js; do
    local name raw gz
    name="$(basename "$f")"
    raw="$(stat -c %s "$f")"
    gz="$(stat -c %s "$f.gz" 2>/dev/null || echo null)"
    [[ $first -eq 1 ]] || echo ","
    first=0
    printf '  "%s": {"bytes": %s, "gzip": %s}' "$name" "$raw" "$gz"
  done
  echo ""
  echo "}"
}

case "${1:-}" in
  build) cmd_build ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  drop) cmd_drop ;;
  clean) cmd_stop || true; cmd_drop; rm -rf "$BENCH_DIR"; echo "removed $BENCH_DIR" ;;
  rpc) cmd_rpc "${2:?usage: $0 rpc EXPR}" ;;
  bundles) cmd_bundles ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
