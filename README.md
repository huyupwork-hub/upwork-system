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
apps/mobile/             Flutter app (Dart source only — see D12)
apps/admin/              Next.js review console (read-only, submitted work only)
supabase/tests/          pgTAP RLS suite
scripts/                 local database verification runner
.github/workflows/       CI quality gates
```

`packages/shared/` is added by the slice that needs it.

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

The script preflights free disk space on Docker's data root. `supabase/postgres` is a large
image, and when the disk is short the CLI reports only `container is not ready: unhealthy` —
the real `initdb: ... No space left on device` is buried in the container log, after the pull
has already been spent. Tune with `MIN_FREE_GB`, bypass with `SKIP_DISK_CHECK=1`.

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
| All four migrations apply against a real Postgres engine | ✅ `supabase/postgres:15.8.1.085`, three times (start, `--no-seed` reset, seeded reset) |
| Migrations apply from empty to head, unseeded (L4) | ✅ on the service box |
| RLS posture: enabled + forced on all four tables | ✅ confirmed |
| Policy inventory | ✅ 23 policies (18 application, 5 storage), no admin write policy |
| pgTAP suite executed | ✅ 5 files on the service box — first run 91/92, the one failure a wrong assertion in 010 (fixed in 620f2cc), suite green after |
| Suite is repeatable (K5) | ❔ **not yet observed** — the first run aborted at the pgTAP step, before it |
| CI green | ❔ **not confirmed here** — a remote now exists; the Actions run is the authoritative record |

Executed by `./scripts/db-verify.sh` on the T410s service box: Postgres only, no Realtime
(D11). The `auth` and `storage` schemas came from the CLI's startup migration jobs, so the
storage policies in `20260831000400_storage.sql` were exercised for real, not against
stand-ins. This supersedes the earlier PGlite smoke check, whose harness was never committed.

Note what this does **not** establish: no service on that box issues a real JWT, signs a
storage URL, or serves the Data API. `request.jwt.claims` is set directly by the test files.
Those paths remain CI-only (D1, D11).

## Running the mobile app

`apps/mobile` commits Dart source only; `android/` and `ios/` are generated (D12).

```bash
cd apps/mobile
flutter create --platforms=android,ios --org com.fieldproof --project-name fieldproof .
git checkout -- lib test pubspec.yaml analysis_options.yaml   # the template rewrites these
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key>
```

The app **fails closed** without those two defines rather than starting in a degraded
state. Only the anon key is ever passed; the privileged key would bypass RLS and has no
place in a client.

### Running the admin console

```bash
cd apps/admin
npm ci
cp .env.example .env.local     # then fill in the two public values
npm run dev
```

| Variable | Value |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | the anon / publishable key — **never** a privileged one |

Both are published into the browser bundle by design and neither confers privilege beyond
what RLS allows. The console refuses to start if the key is not one of the two publishable
shapes (`src/lib/env.ts`), and CI greps the built bundle to prove no privileged key
reached it. The console signs in as an ordinary user and holds no elevated credential: the
admin policies (D3, D23) are what make it a review console.

Slice scope: sign in, sign out, create an inspection, list your own. Photos, PDF, offline
sync and the admin dashboard are later slices and are deliberately absent.
