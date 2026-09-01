# Hosted Supabase smoke test

Proves the Auth → Create Inspection slice against a **real hosted Supabase project**.

Everything under `apps/mobile/test/` runs against in-memory fakes and touches no
network. Those tests prove the client contract — the right payload is sent, errors
surface, a caller cannot name the owner — and they prove **nothing** about RLS. The
pgTAP suite proves RLS against real Postgres, but through `psql`, not through the
app's client path. This test closes the remaining gap: the real client, a real
JWT, real policies, two real users.

**Status: passing.** See [Verified](#verified) below. The case list in this
document covers the auth and ownership core plus the offline-sync cases; the test
file itself is the authoritative list and is numbered to match. The job remains
opt-in via `HOSTED_SMOKE`, so a fork or a fresh clone without the secrets skips it
rather than failing.

## What it asserts

| # | Assertion |
|---|---|
| 1 | User A authenticates with ordinary Supabase Auth; A and B are distinct principals |
| 2 | User A's `profiles` row exists via the `on_auth_user_created` trigger, role `inspector` |
| 3 | User A creates a draft through `SupabaseInspectionsRepository` — the app's own path |
| 4 | User A reads it back through `listMine()` |
| 5 | Stored `inspector_id` equals A's authenticated id, re-read from the server |
| 6 | User B cannot read it — by list, and by direct id |
| 7 | User B cannot update or delete it — asserted against the data afterwards, because RLS denies these *silently* by matching zero rows |
| 8 | User B cannot insert a row owned by A (raises) |
| … | Items, photos, storage, submission immutability, history and search — cases 9–29, listed in the test file |
| 30 | An offline-origin draft syncs to hosted Supabase through the production `DraftSync` and `SupabaseDraftSink` |
| 31 | It arrives as **exactly one** draft, owned by A per RLS, with its fields intact and `submitted_at` null |
| 32 | Both punch items are attached to it, in order, carrying `severity` and `status` — including a `resolved` item, which an ordinary insert would have defaulted to `open` |
| 33 | Replaying the push produces no duplicate: still one inspection, still two items |
| 34 | History and search find it exactly once, by a per-run unique token |
| 35 | User B cannot see it, and B's own queue holding A's id is **refused by RLS** rather than overwriting A's row — B keeps its local copy instead of losing it |
| 36 | After sync it is an ordinary editable draft: the online item-update path works on it |
| 37 | The offline fixture is deleted |

The row is deleted in `tearDownAll`, which also re-proves the owner delete policy.

**How the offline half is modelled.** The offline *phase* is deterministic — a
`LocalDraftBook` over an in-memory store, holding exactly what the device would have
written. The *sync* phase runs against real hosted Supabase through the production
classes. CI does not pull the network interface down: the outcome would then depend on
how quickly the OS reported the change, and a flaky gate teaches people to ignore red.
What only hosted Supabase can answer is asserted here — that a device-generated key
really upserts, that RLS really owns the result, and that a replay really leaves one row.

**Case 36 deliberately stops short of submitting.** D17's delete policy requires the
parent to be a draft, so submitting the fixture would strand an undeletable row in the
hosted project on every run. Submit-after-sync is proven by `offline_flow_test.dart`
through the widget tree, and on hardware by the real-device QA in `ACCEPTANCE.md`.

## Required configuration

Nothing here is committed. Values live in GitHub Actions secrets, or your shell.

| Secret | Value |
|---|---|
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | the **anon / publishable** key — never the service role |
| `SMOKE_USER_A_EMAIL` | an existing, email-confirmed user |
| `SMOKE_USER_A_PASSWORD` | |
| `SMOKE_USER_B_EMAIL` | a **different** existing, confirmed user |
| `SMOKE_USER_B_PASSWORD` | |

Plus one repository **variable** to enable the job:

| Variable | Value |
|---|---|
| `HOSTED_SMOKE` | `true` |

The test refuses to run under a privileged key: it decodes the JWT and requires
`role: anon`, and rejects `sb_secret_` keys. A privileged key bypasses RLS, so
assertions 6–8 would pass while proving nothing.

## Setting it up

1. Create a Supabase project.
2. Apply the schema to it:
   ```bash
   supabase link --project-ref <ref>
   supabase db push
   ```
3. Create two users in **Authentication → Users**, both with "Auto Confirm User"
   enabled. Neither may be an admin — D3 changes what an admin can see, which
   would invalidate assertions 6 and 7.
4. Add the six secrets and the variable:
   ```bash
   gh secret set SUPABASE_URL --repo <owner>/<repo>
   gh secret set SUPABASE_ANON_KEY --repo <owner>/<repo>
   gh secret set SMOKE_USER_A_EMAIL --repo <owner>/<repo>
   gh secret set SMOKE_USER_A_PASSWORD --repo <owner>/<repo>
   gh secret set SMOKE_USER_B_EMAIL --repo <owner>/<repo>
   gh secret set SMOKE_USER_B_PASSWORD --repo <owner>/<repo>
   gh variable set HOSTED_SMOKE --body true --repo <owner>/<repo>
   ```
   `gh secret set` prompts for the value rather than taking it as an argument, so
   nothing lands in shell history.

## Running it

In CI: automatic once `HOSTED_SMOKE=true`, as the `Hosted Supabase smoke test` job.

Locally:

```bash
cd apps/mobile
export SUPABASE_URL='https://<ref>.supabase.co'
export SUPABASE_ANON_KEY='<anon-key>'
export SMOKE_USER_A_EMAIL='a@example.com'
export SMOKE_USER_A_PASSWORD='...'
export SMOKE_USER_B_EMAIL='b@example.com'
export SMOKE_USER_B_PASSWORD='...'
flutter test test_hosted/ --reporter expanded
```

Use a leading space on the `export` lines, or `set +o history`, to keep passwords
out of shell history.

## Deliberate constraints

- **No service-role key anywhere.** The app has no privileged path and neither
  does this test; that is the property under test.
- **No bypass code, no test-only branches in production classes.** The test uses
  `SupabaseAuthRepository`, `SupabaseProfileRepository` and
  `SupabaseInspectionsRepository` exactly as `main.dart` does.
- **Outside `test/`** so `flutter test` stays hermetic and deterministic. A
  network-dependent test in the main suite would make K5 a lie.
- **Credentials via environment, not `--dart-define`.** Defines appear in the
  process command line and in CI step echoes.

---

## Verified

**Run [`33366465489`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33366465489),
job `99408198600`, at `5366a8f` — 8/8 assertions passed** against a real hosted
Supabase project:

```
00:01 +0: 1. user A authenticates with ordinary Supabase Auth
00:02 +1: 2. user A profile exists via the trigger bootstrap path
00:03 +2: 3. user A creates a draft through the app repository path
00:03 +3: 4. user A reads it back
00:03 +4: 5. stored inspector_id is user A
00:03 +5: 6. user B cannot read user A draft
00:04 +6: 7. user B cannot update or delete user A draft
00:04 +7: 8. user B cannot create an inspection owned by user A
00:05 +8: All tests passed!
```

The round trip itself takes ~5 seconds; the job's 7m4s is Flutter setup and
`pub get` on the service box.

## Running it without rebuilding the APK

The smoke test is defined once, in `.github/workflows/hosted-smoke.yml`, with two
entry points:

- **`workflow_dispatch`** — run it alone. No Mobile job, no Gradle, no APK.
  ```bash
  gh workflow run "Hosted Supabase smoke test" --repo <owner>/<repo>
  ```
- **`workflow_call`** — `ci.yml` invokes the same file, so a full push run still
  includes it.

`ci.yml`'s `hosted-smoke` job needs only `detect`, never `mobile`, so it does not
depend on the APK even inside a full run. On a single self-hosted runner the jobs
still execute serially — deliberately, since the box has 5.6 GB of RAM.
