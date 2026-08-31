# FieldProof

A field inspection / punch-list application — Flutter mobile app, Supabase backend, Next.js
admin dashboard. Built as verifiable engineering evidence, not as a startup.

**Status: Gate 0 — foundation only.** No product code yet. See `docs/ACCEPTANCE.md` for
what "done" means and what has actually been demonstrated.

## What it does

An inspector authenticates, creates an inspection, records punch-list items with photos —
continuing to work offline — syncs when connectivity returns, and generates a PDF report.
An administrator reviews submitted inspections from a web dashboard, read-only.

## Documentation

| Document | Purpose |
|---|---|
| [`docs/SPEC.md`](docs/SPEC.md) | Problem, actors, workflows, scope and exclusions |
| [`docs/ACCEPTANCE.md`](docs/ACCEPTANCE.md) | Measurable V1 completion criteria and required evidence |
| [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) | Schema, ownership model, RLS matrix, storage layout |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Decisions that would otherwise become ambiguous |

## Stack

- **Mobile:** Flutter
- **Backend:** Supabase — Postgres, Auth, Storage, Row Level Security
- **Admin:** Next.js + `supabase-js`, deployable to Vercel
- **CI:** GitHub Actions

## Security posture

- RLS is enabled **and forced** on every application table; there is no policy for `anon`,
  so anonymous access is denied by absence rather than by rule.
- Administrators are read-only (`docs/DECISIONS.md` D3).
- `profiles.role` is revoked at the column level from `authenticated`, so a user cannot
  escalate their own role (D4).
- The storage bucket is private; images are served through short-lived signed URLs.
- The `service_role` key never reaches Flutter or the browser. CI asserts it is absent from
  the client bundle and from the tree.

## Setup

Requires: Flutter (stable), Node 22+, the Supabase CLI, and Docker for the local stack.

```bash
cp .env.example .env      # then fill in from the Supabase dashboard
```

Environment variables are documented in `.env.example`.

## Quality gates

Defined in `.github/workflows/ci.yml`. Each gate activates when its slice exists:

| Gate | Command |
|---|---|
| Migrations apply from empty to head | `supabase db reset --no-seed` |
| RLS / pgTAP suite | `supabase test db` |
| Flutter format / analyze / test | `dart format`, `flutter analyze --fatal-infos`, `flutter test` |
| Android release build | `flutter build apk --release` |
| iOS build verification | `flutter build ios --release --no-codesign` |
| Admin lint / typecheck / test / build | `npm run lint`, `npm run typecheck`, `npm test`, `npm run build` |
| Secret hygiene | no tracked `.env`, no `service_role` in tree or client bundle |

## Repository layout

Directories are created when they have a purpose, not to match a template.

```
docs/                    specification, acceptance, data model, decisions
supabase/migrations/     schema + RLS (materialised on Gate 0 acceptance)
supabase/tests/          pgTAP RLS suite
scripts/                 local database verification runner
.github/workflows/       CI quality gates
```

`apps/mobile/`, `apps/admin/` and `packages/shared/` are added by the slices that need them.

## Verification path

Local Postgres, Docker and the Supabase CLI are unavailable on the primary development
machine (D1), so **CI is authoritative**. The database gate runs on every push:

```yaml
supabase start
supabase db reset --no-seed   # L4: migrations apply from empty to head, unseeded
supabase db reset             # re-apply with supabase/seed.sql fixtures
supabase test db              # pgTAP suite
supabase test db && supabase test db   # K5: repeatable, no ordering dependence
```

Each test file runs inside `begin; … rollback;`, so the suite leaves no residue and can be
re-run without a reset. Fixtures live in `supabase/seed.sql` with fixed UUIDs — three
users (two inspectors, one admin), three inspections (two drafts, one submitted), four
items, three photos. Nothing more than the RLS matrix needs.

### Local database verification (service box)

The database gate also runs on a low-powered Linux box, on Postgres alone:

```bash
./scripts/db-verify.sh          # db start -> reset --no-seed -> reset -> test db x3
npx supabase stop               # teardown
```

`supabase db start` brings up the database container only. The `auth` and `storage`
schemas are still created — the CLI applies them as one-shot migration jobs during database
startup rather than from the running services — so the RLS and storage-policy assertions all
hold. **Realtime must stay disabled** (`[realtime] enabled = false`, D11): the CLI runs the
Realtime seeder from inside database startup, and `supabase start -x realtime` does *not*
skip it. On a pre-AVX CPU that seeder aborts with SIGILL (exit 132) before any migration is
applied. CI enforces the flag.

**Limitation, local only:** the service box exercises migrations, Postgres, pgTAP and RLS.
GoTrue, Storage, PostgREST, Kong, Studio and Edge Runtime are not running there, so real JWT
issuance, signed URLs and the Data API stay CI-only. CI is still authoritative (D1).

If the box is suspected of an instruction-set problem, confirm before blaming the image:

```bash
lscpu | sed -n '1,15p'
grep -o -E 'avx2?|sse4_2|popcnt' /proc/cpuinfo | sort -u     # Westmere: sse4_2, no avx
```

### What has actually been verified so far

| Check | Result |
|---|---|
| All four migrations execute against a real Postgres engine | ✅ 4/4 clean — PGlite (Postgres/WASM) under Node |
| RLS posture: enabled + forced on all four tables | ✅ confirmed |
| Policy inventory | ✅ 23 policies (18 application, 5 storage), no admin write policy |
| Behavioural RLS run: role switching across inspector A, inspector B, admin, anon | ✅ 25/25 assertions |
| pgTAP suite executed | ❌ **not yet** — needs CI or a local Docker stack |
| CI green | ❌ **not yet** — no GitHub remote |

The PGlite run was a pre-CI smoke check against stand-ins for the Supabase-managed `auth`
and `storage` schemas. It is not a substitute for `supabase test db`, and its harness is
not committed. No criterion in `ACCEPTANCE.md` is marked met on the strength of it.
