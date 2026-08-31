#!/usr/bin/env bash
#
# Local database verification — migrations, Postgres, pgTAP, RLS. Nothing else.
#
# Runs the same four gate commands as the `database` job in .github/workflows/ci.yml,
# against a Postgres-only local stack. `supabase db start` brings up the database
# container alone; the Auth and Storage schemas still arrive, because the CLI applies
# them as one-shot migration jobs during database startup rather than from the
# long-running services. No Kong, Studio, PostgREST, Edge Runtime — and no Realtime,
# which is disabled in supabase/config.toml (docs/DECISIONS.md D11).
#
# CI remains authoritative (D1). This is a faster local signal, not a replacement:
# it exercises the database gate only.
#
# Usage:  ./scripts/db-verify.sh
# Teardown: npx supabase stop

set -euo pipefail

cd "$(dirname "$0")/.."

# Word-splitting is intentional: the default is a two-word command.
# shellcheck disable=SC2086
supa() { ${SUPABASE_CMD:-npx supabase} "$@"; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\n\033[1merror:\033[0m %s\n' "$1" >&2; exit 1; }

# Preflight. The postgres image plus its data directory need several GB, and when the
# disk is short the CLI surfaces only "container is not ready: unhealthy" — the real
# cause ("initdb: ... No space left on device") is buried in the container log, after a
# long image pull has already been spent. Fail early and legibly instead.
# MIN_FREE_GB is a floor, not a measurement; raise it if a pull still runs the disk out.
: "${MIN_FREE_GB:=5}"
if [ -z "${SKIP_DISK_CHECK:-}" ] && command -v docker >/dev/null 2>&1; then
  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  [ -n "$docker_root" ] && [ -d "$docker_root" ] || docker_root=/var/lib/docker
  if [ -d "$docker_root" ]; then
    free_gb=$(df -Pk "$docker_root" | awk 'NR==2 {print int($4/1048576)}')
    if [ "${free_gb:-0}" -lt "$MIN_FREE_GB" ]; then
      printf '\n' >&2
      df -h "$docker_root" >&2
      docker system df >&2 || true
      die "only ${free_gb}G free on $docker_root; need >= ${MIN_FREE_GB}G.
  Reclaim, least destructive first:
    npx supabase stop --no-backup     # drop any half-built local stack + its volume
    docker system df                  # see what is actually holding the space
    docker image prune -af            # unreferenced images
    docker builder prune -af          # build cache
    sudo apt-get clean                # apt package cache
    sudo journalctl --vacuum-size=100M
  If the disk is simply too small, move Docker's data root to a larger volume via
  /etc/docker/daemon.json (\"data-root\"), rather than trimming the stack further:
  supabase/postgres is the only supported local database image.
  Override this check with SKIP_DISK_CHECK=1 once you know the space is there."
    fi
  fi
fi

step 'Database up (Postgres only; migrations + seed applied)'
supa db start

# L4 — migrations apply from an empty database to head with no seed data involved.
# A migration that only works against a pre-seeded database fails here.
step 'L4: migrations apply cleanly from empty to head, unseeded'
supa db reset --no-seed

step 'Re-apply with the deterministic fixtures in supabase/seed.sql'
supa db reset

step 'RLS / pgTAP suite'
supa test db

# K5 — determinism. Each test file runs in its own transaction and rolls back, so a
# repeat run must produce identical results. Ordering dependence shows up here.
step 'K5: suite is repeatable'
supa test db && supa test db

printf '\n\033[1mDatabase gate passed locally.\033[0m CI is still the authoritative gate (D1).\n'
