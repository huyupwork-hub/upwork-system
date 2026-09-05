# Deployment

What is live, where it lives, how to put it there again, and what this deployment does
not do. Every value below was read from the live service or the repository rather than
copied from an earlier document. Anything that could not be verified says so instead of
guessing.

---

## 1. Live URLs

| | |
|---|---|
| Review console | https://upwork-system-thun-viet.vercel.app |
| Android build | https://github.com/huyupwork-hub/upwork-system/releases/tag/v0.1.0-demo.2 (`fieldproof-76339db.apk`) |
| Portfolio page | https://huypkc.github.io/projects/fieldproof/ |

The console URL is an alias of a production deployment, not a deployment URL of its own.
Verified 2026-09-05: it answers `307` to `/` and redirects to sign-in, and the page titles
itself *FieldProof Review*.

---

## 2. Demo credentials

Published on purpose. Both accounts are demo-only, the project holds only demo data, and
the security model is the part worth reviewing, so it should be possible to push against
it. The walkthrough these belong to is in [`DEMO.md`](DEMO.md).

| Role | Email | Password |
|---|---|---|
| Admin, web console | `fieldproof-demo-admin@yopmail.com` | `DemoAdmin2026!` |
| Inspector, Android | `fieldproof-demo-inspector@yopmail.com` | `DemoInspector2026!` |

**The admin account is read-only, and that is enforced by policy rather than by hiding
buttons.** Verified 2026-09-05 by calling PostgREST directly as that account:

| Attempt | Result |
|---|---|
| `POST /rest/v1/inspections` | `403` · `42501 new row violates row-level security policy` |
| `PATCH /rest/v1/inspections?id=eq.…` | `200`, body `[]` — RLS matched zero rows, nothing written |
| `DELETE /rest/v1/inspections?id=eq.…` | `200`, body `[]` — RLS matched zero rows, nothing written |

The table was re-read afterwards and was unchanged. The `200` on update and delete is
PostgREST reporting a zero-row write as success: the `USING` clause filters every row out
before the write is considered. Nothing is writable; a client that read `200` as "saved"
would be wrong, but the console offers no edit control. `hosted-smoke.yml` documents the
same behaviour for its own cleanup.

---

## 3. Supabase

| | |
|---|---|
| Project ref | `dkgrpoudebqvtpxdetdg` |
| Region | `ap-south-1` |
| Postgres | 17 |
| Keys in the browser | publishable key only. The app refuses to start with a privileged one |

### Migrations

| Id | Purpose | Applied to prod |
|---|---|---|
| `20260831000100_schema` | tables, enums, constraints | yes |
| `20260831000200_functions` | triggers, `is_admin` | yes |
| `20260831000300_rls` | the RLS matrix | yes |
| `20260831000400_storage` | private photo bucket | yes |
| `20260831000500_submitted_immutable` | D17, submitted work frozen | yes |
| `20260905000600_function_hardening` | withdraw default EXECUTE, pin `search_path` | yes — 2026-09-05 |
| `20260905000700_signup_gate` | close self-signup at the database | yes — 2026-09-05 |
| `20260905000800_remove_stranded_qa_inspection` | delete one QA row | yes — 2026-09-05 |

The last three were applied with `supabase db push` on 2026-09-05, after CI run
`33935381654` (§5) had executed them from empty and from seed and run the pgTAP suite
against them three times. `supabase migration list` shows all eight local ids matched
remotely. Read back from the live project afterwards, through the management API's SQL
endpoint:

| Check | Result |
|---|---|
| `pg_proc.proconfig` on `set_updated_at`, `enforce_submission_transition`, `handle_new_user`, `is_admin` | `search_path=""` on all four |
| `has_function_privilege(role, fn, 'execute')` for `anon` and `authenticated` on the three trigger functions | `false` for all six |
| `public.signup_allowlist` | RLS forced, 5 rows (three CI fixtures, two demo accounts) |
| `inspections` row `41c43817…` (*Device QA Persistence 123726*) | gone |
| Supabase security advisor | `function_search_path_mutable` no longer reported; `rls_enabled_no_policy` on `signup_allowlist` and `authenticated_security_definer_function_executable` on `is_admin()` remain, both deliberate — the allowlist has no policy on purpose, and `is_admin()` is reviewed in `20260905000600`; `auth_leaked_password_protection` (WARN) is an Auth setting, not in this repository |

One consequence of the allowlist to know about: its five rows are the local seed's three
fixture addresses and the two published demo accounts. The hosted smoke users A and B and
one personal admin profile exist in the project but are not on it, which is fine while
those `auth.users` rows exist and would stop them being re-created through sign-up if they
were ever deleted.

### Self-signup: closed at the database and in Auth configuration

`20260905000700_signup_gate` is applied: `handle_new_user()` now refuses any address not
in `signup_allowlist`, so a stranger's sign-up fails at the trigger and strands neither an
`auth.users` row nor a profile (proved by `supabase/tests/100_signup_gate.test.sql`).

The project-level toggle is a separate thing, not in this repository. It was turned off in
the dashboard on 2026-09-05 (Authentication → Sign In / Providers → *Allow new users to
sign up*): `GET /auth/v1/settings` read `"disable_signup": false` after the migration and
`true` after the toggle. Should it ever come back on, the database still refuses; the
setting can also be restored with:

```
PATCH https://api.supabase.com/v1/projects/dkgrpoudebqvtpxdetdg/config/auth
{"disable_signup": true}
```

Both halves are wanted. The toggle gives the clean refusal; the migration survives a
configuration change nobody reviewed.

---

## 4. Redeploy

### Review console (Vercel)

| | |
|---|---|
| Project | `prj_maHwdAHkJeLnH2e7tRJ4fObIdnjG`, scope `thun-viet` |
| Root directory | `apps/admin` |
| Framework | Next.js, Node 24.x, region `iad1` |

**Push to `main`.** That is the route, and it always was: Vercel's own record
(`vercel api /v13/deployments/<id>`, which shows the `gitSource` that `vercel inspect`
hides) lists git-triggered production deployments of `main` at `3469eea` (2026-09-01),
`ffef50e` and `6fc2ee5` (2026-09-02) and `76339db` (2026-09-05, merge of PR #6,
`dpl_44uJ3krZS6oZHgDj9cCmjDCWVyu2`). The earlier note here — that auto-deploy was off
because the Vercel account is not linked to the committing identity — was never true of
this project, and neither was the "unknown commit" that followed from it. The public alias
resolves to `dpl_44uJ3krZS6oZHgDj9cCmjDCWVyu2` as of 2026-09-05.

**By hand only if a push cannot do it.** The project's Root Directory is `apps/admin`, so
the upload must contain that path: run from `apps/admin` the CLI fails with *The specified
Root Directory "apps/admin" does not exist*. Run from the repository root instead
(`.vercel/` is ignored there, `.gitignore` line 48, so `vercel link` is safe). The
condition is the root `.vercelignore`, which must stay: the CLI ships the checkout
*including git-ignored files*, and on 2026-09-05 a root deployment carried the local
`.env` and `supabase/.temp/` that way. That deployment (`dpl_9xpTHaaq…`) and a failed
one from `apps/admin` were deleted the same morning and the alias returned to the git
build; the values in that `.env` (two smoke passwords and an admin password) should be
treated as seen by the Vercel team.

```bash
vercel link --yes --scope thun-viet --project upwork-system   # once, at the root
vercel deploy --prod --scope thun-viet --yes -m githubCommitSha=<sha> -m githubCommitRef=main
```

### Android APK

CI already builds a commit-tagged release APK, so a release should take that artifact
rather than a local build. `v0.1.0-demo.2` was cut that way: artifact
`fieldproof-android-ef90622f…` from run `33935381654`, sha256
`2d1d0fdcd79269342c3bf91dbbdad2ca28eef9f37d2eb74af18176e274a12f3a`, attached as
`fieldproof-76339db.apk`. On a `pull_request` run `github.sha` is the PR *merge* commit,
not the head: `ef90622f` is *Merge 882d9c9 into 6fc2ee5*, and its tree `942bb45b` is the
tree of `main` at `76339db` (checked with `git rev-parse <commit>^{tree}` on both), which
is why the asset is named after the `main` commit.

```
artifact   fieldproof-android-<sha>
path       apps/mobile/build/app/outputs/flutter-apk/app-release.apk
```

The equivalent local command, which produces an APK tied to nothing:

```bash
flutter build apk --release \
  --dart-define=SUPABASE_URL=… \
  --dart-define=SUPABASE_ANON_KEY=…
```

Note CI patches `AndroidManifest.xml` to grant `INTERNET` before building: the Flutter
template grants it only in debug and profile, so a release build would have no network and
every Supabase call would fail.

### Database

```bash
supabase link --project-ref dkgrpoudebqvtpxdetdg
supabase db push
```

---

## 5. CI run

| Run | Commit | Result |
|---|---|---|
| https://github.com/huyupwork-hub/upwork-system/actions/runs/33935381654 | PR #6 at `882d9c9` (merge ref `ef90622f`, tree = `main@76339db`) | all gates green: migrations from empty and from seed, pgTAP 11 files / 208 assertions ×3, Mobile, Admin, hosted smoke |
| https://github.com/huyupwork-hub/upwork-system/actions/runs/33936856376 | `main` at `76339db` | all gates green on the merge commit itself, including the same database gate and a fresh `fieldproof-android-76339db…` artifact |

The two runs before those tell the rest of the story and are kept for that reason:
`33922739927` was cancelled by a later push; `33933212105` failed once on the runner
(another project's local Supabase stack held port 54322 — fixed by `882d9c9`, which gives
this project `[db] port = 54332`) and, re-run, failed pgTAP 095 on the spelling of an
empty `search_path` in `proconfig` — fixed by `57e46b0`. Wherever a database job got as
far as applying the migrations — `33933212105` attempt 2, `33935381654`, `33936856376` —
all eight applied cleanly, from empty and from seed; attempt 1 of `33933212105` died
starting the container before applying any.

**Runner.** From 2026-09-04 21:15Z (run `33920282984`, never started) until 2026-09-05
00:27Z (first job of `33922739927`) the repository had no registered runner. The cause is
on the box, not in the API: the runner's own `_diag/Runner_20260904-162456-utc.log` ends
with *The runner registration has been deleted from the server… runners that have not
connected to the service recently*, and its `.runner` file pointed at another repository,
having been reconfigured on 2026-09-03. It was re-registered for this repository on
2026-09-05 as `huy-ThinkPad-T410s` with work folder `/data/runner-work`, so the D16 caches
apply. **Open:** the repository is public and every job still declares
`runs-on: [self-hosted, Linux, X64]`. D15 says to move `runs-on` to GitHub-hosted in that
situation; what is in place instead is `fork-pr-contributor-approval =
all_external_contributors`, which only gates when a fork's workflow may start. That is
the owner's decision and it has not been taken.

**Smoke cleanup does not delete anything.** The `Purge this run's fixtures` job exits 0
with *SUPABASE_SERVICE_ROLE_KEY is not set* — although the `hosted-smoke-cleanup`
environment has held a secret of that name since 2026-09-01. Two things are wrong at once:

1. On the `ci.yml` path the key never reaches the job. `ci.yml` calls `hosted-smoke.yml`
   with an enumerated `secrets:` list that deliberately omits it, and a called workflow's
   `secrets` context holds only what the caller passes — the environment binding on the
   cleanup job does not add to it. So the design in `SMOKE_TEST.md` (key from the
   environment, boundary from the list) holds the boundary but starves the job.
2. On the standalone path the stored value is bad. `workflow_dispatch` run `33571900589`
   (2026-09-01 23:38Z) did resolve the secret, attempted the deletes, and got
   `401 Invalid API key`.

Each hosted smoke *execution* therefore leaves one submitted
`SMOKE run<id>x1 submitted do-not-keep` inspection in the live project, visible to the
demo admin; three exist as of 2026-09-05 (`5113fcd3…`, `72a60c84…`, `4a3a40f3…`, from
runs `33933212105`, `33935381654`, `33936856376`; the cancelled `33922739927` never ran
its smoke; a fourth, from `33938892430`, followed the docs push). Two fixes, both in
`fix/smoke-cleanup-path`: `.github/workflows/smoke-cleanup.yml` moves the purge into a
`workflow_run` of its own, where the environment secret resolves and `ci.yml` still never
names the key (the design PR #5 arrived at on 2026-09-02, cherry-picked); and
`20260905000900_remove_smoke_residue` deletes the four rows by explicit id, the only route
D17 and the channel leave for a submitted row. The key itself was replaced in the
environment on 2026-09-05 02:47Z.

---

## 6. What is mocked, limited, or unverified

**The deployed commit is `76339db` on `main`** (2026-09-05): the public alias resolves to
the git-triggered deployment `dpl_44uJ3krZS6oZHgDj9cCmjDCWVyu2`, whose `gitSource` records
it, and the APK in `v0.1.0-demo.2` is built from the same tree (§4). The deployment before
it, `dpl_7mY5ksjdvqk8jC9NqZtRWuQpKPRh` (2026-09-02), was likewise a git build — of
`6fc2ee5`, the merge of PR #4 — which the previous version of this page called unknown
because `vercel inspect` does not print git metadata; `vercel api /v13/deployments/<id>`
does.

**Self-signup** is off at both layers as of 2026-09-05 (§3); the toggle lives outside the
repository, so a configuration change nobody reviewed would reopen the clean refusal but
not the door.

**Reports are generated on the device, and nothing is stored.** PDF rendering is Flutter-only
(D6), the PDF is a projection rather than an artefact (D21), and the console deliberately
contains no second PDF engine (D23). The console says so on screen. There is no cloud PDF,
and the demo admin cannot download one.

**Offline photo capture does not work.** Drafts and punch items work offline; attaching a
photo does not. Deferred with its reasoning in `DECISIONS.md` D27.

**Cold start when opened offline takes around 30 seconds.** The history waits for a profile
lookup to fail before rendering. Latency, not a correctness problem.

**iOS is unverified.** It needs a macOS runner, which this project has never had.

**Seed data.** Three demo inspections are submitted (Northgate Retail Park with two
photographs, Harbour View Apartments with one, Meridian Distribution Centre with none) and
one, Cavendish House, is a draft. The stranded QA row is gone. What the demo admin also
sees is test residue: one `SMOKE run… do-not-keep` row per hosted smoke run, for the
reason in §5, until the cleanup key is configured.

**Storage is private.** Photographs are served through short-lived signed URLs; the bucket
has no public path.
