# Hosted Supabase smoke test

Proves the Auth → Create Inspection slice — and, since D31, the stored report — against
a **real hosted Supabase project**.

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
| … | Items, photos, storage, submission immutability — cases 9–22, listed in the test file |
| 22a | User A publishes the submitted inspection's report through `ReportService` — the real `ReportLoader`, `PdfReportRenderer` and `SupabaseReportStore`, A's session — at exactly `{uid}/{inspection_id}/report.pdf`; `published()` lists the id (the listing reflects the object); a signed URL serves 200 `application/pdf` beginning `%PDF-`; the unsigned URL does not serve |
| 22b | Write-once through the Storage API, as the owner: a second upload at the pinned name is refused as `Duplicate` (`statusCode 409`), the shape `SupabaseReportStore.put` reads as "already there"; `upsert: true` is refused (no UPDATE policy); `remove()` completes with `[]` and the object is still listed (no DELETE policy); a re-download is byte-identical to 22a; `SupabaseReportStore.put` at the same name completes without replacing it |
| 22c | User B cannot list A's inspection folder or A's folder of inspections, cannot sign the report, and cannot upload at the pinned name or at a sibling name beside it; A's folder still holds only `report.pdf` |
| 22d | A draft cannot have a stored report: the raw upload under a draft is refused at the server, `publish(draft)` raises `InspectionNotSubmittedException` without submitting, and the draft is deleted |
| 22e | `publishMissing` over the already-published inspection uploads nothing — the backfill vehicle run twice — and the folder still holds exactly one object |
| … | Deletion under submission, history and search — cases 23–29, listed in the test file |
| 30 | An offline-origin draft syncs to hosted Supabase through the production `DraftSync` and `SupabaseDraftSink` |
| 31 | It arrives as **exactly one** draft, owned by A per RLS, with its fields intact and `submitted_at` null |
| 32 | Both punch items are attached to it, in order, carrying `severity` and `status` — including a `resolved` item, which an ordinary insert would have defaulted to `open` |
| 33 | Replaying the push produces no duplicate: still one inspection, still two items |
| 34 | History and search find it exactly once, by a per-run unique token |
| 35 | User B cannot see it, and B's own queue holding A's id is **refused by RLS** rather than overwriting A's row — B keeps its local copy instead of losing it |
| 36 | After sync it is an ordinary editable draft: the online item-update path works on it |
| 37 | The offline fixture is deleted |
| 38 | The only residue is the submitted inspection, its one item and its one report object — the three the purge removes — and the report's folder holds nothing but `report.pdf` |

The row is deleted in `tearDownAll`, which also re-proves the owner delete policy.

**What the report cases are evidence for.** pgTAP `110` proves the `inspection-reports`
policies through SQL. Cases 22a–22e own the half only the hosted project can answer: how
the Storage API spells each refusal (`Duplicate` for a second write, a refusal for
`x-upsert`, `[]` for `remove()`), that a folder listing reflects the object beneath it and
runs under the caller's role, and that the app's own publish path meets the one name the
policy pins. If the live storage-api ever spells a refusal differently, 22a–22b go red and
`SupabaseReportStore` in `supabase_repositories.dart` is the one place to adjust.

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
   Cases 22a–22e need the `inspection-reports` bucket and its three policies, which
   `20260905001100_inspection_reports.sql` creates. A project behind that migration
   fails 22a on the upload with a bucket-not-found refusal — loudly, not silently.
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

- **No privileged key in the app, and none in this test.** The app has no
  privileged path and neither does the test: it decodes the key it is handed
  and refuses to start unless the claim is `anon`, because a privileged key
  would bypass RLS and every isolation assertion here would pass while proving
  nothing. That property is unchanged.

  What is new is a *separate* cleanup step that runs after the test process has
  exited, holding a key the test never sees. See [Cleanup](#cleanup) — it
  changes no policy and gives no client any new power.
- **No bypass code, no test-only branches in production classes.** The test uses
  `SupabaseAuthRepository`, `SupabaseProfileRepository` and
  `SupabaseInspectionsRepository` exactly as `main.dart` does.
- **Outside `test/`** so `flutter test` stays hermetic and deterministic. A
  network-dependent test in the main suite would make K5 a lie.
- **Credentials via environment, not `--dart-define`.** Defines appear in the
  process command line and in CI step echoes.

---

## Cleanup

A smoke run creates inspections, punch items, a photo, a photo object and a report
object, and removes each one as it goes. Two fixtures it cannot remove. Case 22
submits an inspection on purpose, submit is one-way (D10), and the delete policy
requires `status = 'draft'` (D17). The run's own teardown therefore matched zero
rows and succeeded silently, leaving one `SMOKE … do-not-keep` row in the shared
project per CI run. Six had accumulated before anyone looked at the demo queue.
Case 22a then stores that inspection's report in `inspection-reports`, a bucket
with no DELETE policy for any role (D21 amended, D31): `remove()` matches zero rows
and returns `[]`, which case 22b proves, so a run may leave one inspection, one item
and one report object, and nothing else.

### Where the privileged key lives

Two workflows, one boundary between them.

| Workflow / job | Environment | Holds the key |
| --- | --- | --- |
| `hosted-smoke.yml` → `smoke` | none | **No.** `ci.yml` passes six secrets by name and this is not one of them. The test also decodes the key it is given and refuses to start unless the claim is `anon`. |
| `smoke-cleanup.yml` → `purge` | `hosted-smoke-cleanup` | **Yes, and only here.** |

Cleanup is a separate workflow rather than a second job, and that is not
cosmetic. It *was* a job in `hosted-smoke.yml`, gated by the same environment,
and it never ran — proven by two runs of the same job:

| Invocation | `SUPABASE_SERVICE_ROLE_KEY` |
| --- | --- |
| `workflow_dispatch` on hosted-smoke.yml | `***` |
| `pull_request` → ci.yml → `workflow_call` | *(blank)* |

In a workflow invoked with `workflow_call`, the `secrets` context holds only
what the caller passed; environment secrets are not merged in. `SUPABASE_URL`
resolved in both because ci.yml passes it by name. Passing the cleanup key the
same way would have worked and would have put it in scope for the whole called
workflow, including the smoke job — the thing this separation exists to prevent.
A `workflow_run` fires a real run of its own, where an environment secret
resolves normally.

It listens for **CI** as well as for the smoke workflow: a reusable workflow
invoked with `workflow_call` produces no run of its own, so listening only for
"Hosted Supabase smoke test" would catch the manual dispatch and miss every push
and pull request — the path that actually accumulates rows.

`workflow_run` only fires for a workflow file that exists on the **default
branch**, so cleanup starts working once this is merged, not while it sits on a
branch.

No other job in the repository — Database + RLS, Mobile, Admin, Secret hygiene —
names a privileged secret at all.

The boundary holds only while the secret exists **solely** as an environment
secret. A repository-level secret of the same name resolves in any job that
names it, which is why the setup below deletes one if it is there.

### Scope

Explicit identifiers, and nothing else:

- inspection ids, item ids, photo object paths (`inspection-photos`) and report
  object paths (`inspection-reports`) the run recorded **as it created each
  one**; or
- the same four named on the command line — `--inspection`, `--item`,
  `--object`, `--report` — for the one-off below.

There is no pattern match anywhere in the script: no delete by name, owner,
date, status or prefix. A missing or stale manifest deletes nothing — a cleanup
that cannot name its target does not guess.

Storage objects in both buckets go through the **Storage API, never SQL**.
Postgres refuses a direct delete from `storage.objects` (`protect_delete()`),
because removing the row would leave the backing file behind for good. Targets
are bucket-qualified: a path says nothing about which bucket holds it, so the
manifest records photo objects under `storagePaths` and report objects under
`reportPaths`, and the log names the bucket on every object line.

Ordering is photo objects, then report objects, then items, then inspections.
Deleting the row first strands the bytes: a photo object's own delete policy
reaches through the owning inspection, so afterwards nothing can reach it —
which is how the orphans below were made. A report object has no client delete
path at all, whatever the row's state; it goes before the rows for the same
reason, so a failure between the two leaves a nameable object rather than an
orphan.

The manifest is flushed on every registration rather than at the end, because
the run it exists for is the one that dies halfway. It crosses between the two
jobs as a build artifact and holds UUIDs and storage paths only — no
credentials, no user data. The report path is registered *before* the upload
(its name is fixed by the policy), so a process that dies with the object landed
and no response read still names it.

Case 38 is the regression guard. It asks the server which of the run's rows,
items and report objects are still standing and requires the answer to be
exactly one inspection, its one item and its one report object — the three that
cases 22, 23 and 22b prove cannot be deleted by any client. A fixture added
later without cleanup fails it. The purge's last line counts what it removed and
ends `nothing named remains`.

### Enabling it

Two settings. The value never has to reach a shell history or a transcript:
`gh secret set` prompts for it.

```
# 1. the environment (already created; harmless to repeat)
gh api --method PUT repos/<owner>/<repo>/environments/hosted-smoke-cleanup

# 2. the key, scoped to that environment and nowhere else
gh secret set SUPABASE_SERVICE_ROLE_KEY --env hosted-smoke-cleanup --repo <owner>/<repo>

# 3. remove any repository-level copy, or the boundary is decoration
gh secret delete SUPABASE_SERVICE_ROLE_KEY --repo <owner>/<repo>
```

Get the key from the Supabase dashboard under Project Settings → API Keys.
Until it is set the cleanup job warns and exits 0, so a fork or a fresh clone is
not permanently red — but the row is not removed either.

Optional hardening, both scoped to the cleanup job alone: required reviewers on
the environment, or a deployment branch policy limiting which branches may use
it.

### One-off cleanup

The same audited script, with targets named on the command line instead of read
from a manifest. Use it for artefacts no run recorded.

```
cd apps/mobile
export SUPABASE_URL=https://<ref>.supabase.co
read -rs SUPABASE_SERVICE_ROLE_KEY && export SUPABASE_SERVICE_ROLE_KEY

dart run tool/smoke_purge.dart \
  --object 'd71ee5ce-4668-4354-aadc-e0ec8f4b4b81/553e786f-41f8-4b6b-bbee-fe7acbbe2562/53e9e7e8-2cc8-43e5-88c8-ddc5ebb4bbf6/67a94794-3213-49db-9764-e0e475f4dd02.png' \
  --object 'd71ee5ce-4668-4354-aadc-e0ec8f4b4b81/55010928-4a27-48e5-9162-cca67769b662/9eaec459-150b-44d8-92a8-255a59dfc865/2c3b9aae-0828-4226-ac88-a6f5b6a65065.jpg'
```

Those two objects are orphans: their parent inspections no longer exist and
neither has an `item_photos` row, so no client can list, sign or delete them.
67 bytes and 134,595 bytes. The first is the smoke test's own `_tinyPng`
fixture; the second is a real photo from the device QA in `docs/ACCEPTANCE.md`.

A stranded report object — a run whose manifest was lost after case 22a — is
named the same way, in its own bucket:

```
dart run tool/smoke_purge.dart \
  --report '<inspector uid>/<inspection id>/report.pdf'
```

`--object` is `inspection-photos` and `--report` is `inspection-reports`; the
script never guesses a bucket from a path.

The device-QA inspection is a separate call, and one to make deliberately:

```
dart run tool/smoke_purge.dart \
  --item 3f0be5a6-f31a-4309-857c-ae815895f5fc \
  --inspection 41c43817-5907-4b4a-b39f-26c6c7d32964
```

Verified before writing those ids down, because deleting the wrong record here
is not recoverable:

| Check | Result |
| --- | --- |
| `ACCEPTANCE.md` case 23 | `Device QA Persistence 123726` + one `High` item in `Boiler room` |
| Row `41c43817-…` | that exact name, address `9 Persistence Road`, client `Persistence QA Client` |
| Its one item `3f0be5a6-…` | `High`, area `Boiler room` — matches the record |
| Owner | `fieldproof-smoke-a`, the test account — **not** `Dana Okonjo`, who owns the demo records |

It is a QA artefact, not a portfolio record. It is also still visible in the
public demo queue, which is the reason to remove it — but it is evidence for an
acceptance case, so removing it is a judgement call rather than housekeeping.

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
