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
