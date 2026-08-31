# V1 Acceptance Criteria

V1 is complete when **every** criterion below is satisfied *and* the named evidence exists.

Rules of this document:

- "The UI works" is never sufficient. Each criterion names its verification.
- Evidence must be reproducible by another engineer from a clean checkout.
- A criterion with a failing or skipped test is not met. Failures are reported, never masked.

Status key: ☐ not started · ◐ in progress · ☑ met with evidence

---

## A. Authentication

| # | Criterion | Evidence |
|---|---|---|
| A1 | ☑ An existing user signs in with email + password. **Sign-up is out of V1 scope (D13)** — accounts come from the dashboard or seed. | **Hosted smoke ✅ run `33366465489`** assertion 1 — real Supabase Auth, real JWT |
| A2 | ☑ A `profiles` row with role `inspector` is created automatically on signup. | **Hosted smoke ✅ run `33366465489`** assertion 2 — row created by the `on_auth_user_created` trigger, role `inspector`, read through `SupabaseProfileRepository` |
| A3 | ◐ Sign-out clears the session; the protected screen unmounts and sign-in returns. | Widget test ✅ run `606017a` proves the routing. The hosted smoke calls `signOut()` in teardown but asserts nothing about it, so real session teardown remains unverified |
| A4 | ☑ An unauthenticated client is refused by every application table (raises `42501`; stricter than returning zero rows). | CI run `d53d066` ✅ |
| A5 | ☑ A user cannot escalate their own role to `admin`, but can still rename themselves. | CI run `d53d066` ✅ |

## B. Inspection CRUD

| # | Criterion | Evidence |
|---|---|---|
| B1 | ☑ An inspector creates an inspection with site name, address, client, and date. | **Hosted smoke ✅ run `33366465489`** assertions 3–5 — created through `SupabaseInspectionsRepository`, read back via `listMine()`, and `inspector_id` re-read from the server equals the authenticated uid |
| B2 | ☑ Required-field and length constraints reject invalid input at the database, not only in the UI. | CI run `d53d066` ✅ |
| B3 | ☐ An inspector can edit and delete their own inspection. | Flutter test |
| B4 | ☑ Deleting an inspection cascades to its items and photo rows. | CI run `d53d066` ✅ |
| B5 | ☑ A submitted inspection cannot be returned to draft (D10), and `submitted_at` is stamped automatically. | CI run `d53d066` ✅ |
| B6 | ☑ **A submitted inspection is immutable (D17)**: its owner cannot edit or delete it. | pgTAP `070` ✅ run `33384740243` — silent zero-row denial, verified against the data |
| B7 | ☑ Drafts are unaffected, and a draft can still be submitted. | pgTAP `070` ✅ — edit, add item, submit, then immutable from that moment |

## C. Punch-list items

| # | Criterion | Evidence |
|---|---|---|
| C1 | ☑ Items can be added, edited, and deleted within an inspection. | **Hosted smoke ✅ run `33375863716`** assertions 9–11 and 15 (real client path) + widget coverage in `item_flow_test.dart` |
| C2 | ☐ Items can be reordered, and the order survives a reload. | Not implemented — `sort_order` is set on append only; reordering is a later slice |
| C3 | ☑ Severity and status are constrained to their enums. | CI run `d53d066` ✅ · pgTAP `060` rejects `major` and `in-review` (`22P02`) |
| C4 | ☑ An item can be resolved **and reopened** — the transition is not one-way. | **Hosted smoke ✅ run `33375863716`** assertion 12 · pgTAP `060` |
| C5 | ☑ Item ownership derives through the parent inspection: another inspector cannot read, create, update or delete items under it. | **Hosted smoke ✅** assertions 13–14 · pgTAP `060` both directions, including the silent zero-row denial |
| C6 | ☑ The client rejects Figma's enum vocabulary rather than silently accepting it. | `item_models_test.dart` — `minor`, `major`, `in-review` all raise; `constraint_parity_test.dart` reads both enums from the migration |
| C7 | ☑ Items under a submitted inspection cannot be created, edited, resolved/reopened, or deleted (D17). | pgTAP `070` ✅ run `33384740243` — INSERT raises `42501`; UPDATE/DELETE deny silently and the data is re-read to prove it |
| C8 | ☑ The app presents a submitted inspection as read-only: no add affordance, rows inert, reason stated. | Widget tests in `item_flow_test.dart` ✅ run `33384740243` — presentation only; the database is the enforcement |

## D. Photos

| # | Criterion | Evidence |
|---|---|---|
| D1 | ☑ One or more photos attach to an item and upload to the private bucket. | **Hosted smoke ✅ run `33392138378`** cases 15–16 — a real PNG through real Supabase Storage, metadata row persisted and read back |
| D2 | ☑ Objects are stored at `{inspector_id}/{inspection_id}/{item_id}/{photo_id}.{ext}`, with the owner segment taken from the session. | Hosted smoke case 15 asserts the path starts with A's authenticated uid · `photo_workflow_test.dart` asserts all four segments |
| D3 | ☑ Photos render from short-lived signed URLs, never a public URL. | **Hosted smoke case 17** the signed URL returns 200 · **case 18** the unsigned path does **not** — the bucket really is private · pgTAP `080` asserts `buckets.public = false` |
| D4 | ☑ Uploads outside the caller's own prefix are rejected. | pgTAP `080` ✅ — cross-prefix and cross-owner-inspection uploads both raise `42501` · **hosted smoke case 20** B cannot upload under A's prefix through the real Storage API |
| D5 | ☑ Oversized (>10 MB) or non-image uploads are rejected. | `photo_workflow_test.dart` rejects both before any bytes leave the device · the same limits are CHECK constraints on `item_photos` (pgTAP `050`) and on the bucket |
| D6 | ☑ A submitted parent blocks photo mutation at the database, not only in the UI. | **Hosted smoke case 22** ✅ · pgTAP `070` (metadata) and `080` (storage object) both refuse under a submitted inspection (D17) |
| D7 | ☑ Another inspector cannot read, sign, or delete an object, and the metadata cannot describe one they could not write. | **Hosted smoke case 19** ✅ — list, direct id, signed URL and delete all refused · pgTAP `080` |
| D8 | ☑ Upload is object→metadata, and a failed metadata insert deletes the uploaded object (D19). | `photo_workflow_test.dart` ✅ run `33403013321` — forces the insert failure and asserts the bucket is left empty; also that the *original* error survives a failing compensation |
| D9 | ☑ Delete is metadata→object, and a failed object delete surfaces without resurrecting the row (D19). | `photo_workflow_test.dart` ✅ — asserts the row stays deleted, the orphan is named in `PhotoCleanupException`, and a refused metadata delete leaves the object untouched |

## E. Offline drafts

| # | Criterion | Evidence |
|---|---|---|
| E1 | ☐ With connectivity disabled, an inspector creates and edits a draft inspection with items and photos. | Flutter integration test, network stubbed offline |
| E2 | ☐ A local draft survives an app restart. | Flutter test: kill + relaunch, draft intact |
| E3 | ☐ No local change is discarded without an explicit user action. | Test asserting no silent-drop path |
| E4 | ☐ Draft state is visibly distinguishable from synced state in the UI. | Screenshot |

## F. Synchronization

| # | Criterion | Evidence |
|---|---|---|
| F1 | ☐ On reconnect, pending drafts push to Supabase and are marked synced. | Flutter integration test |
| F2 | ◐ Sync is idempotent — running it twice produces no duplicate rows. | pgTAP `050` ✅ run `d53d066` at the database level; no Flutter sync layer exists yet |
| F3 | ☐ An interrupted sync resumes without data loss or duplication. | Test: fail mid-push, retry, assert consistency |
| F4 | ☐ Sync failures surface to the user; they are never swallowed. | Test asserting error state is rendered |

## G. PDF

| # | Criterion | Evidence |
|---|---|---|
| G1 | ◐ A PDF generates on-device with no network connection. | **Rendering is offline** — `PdfReportRenderer` is pure, takes a snapshot and returns bytes, and `report_renderer_test.dart` runs it with no network at all. **Loading the snapshot still needs the network**, so end-to-end offline generation belongs to the offline slice, not this one |
| G2 | ◐ It contains site info, inspector name, inspection date, and every item with description, area, severity and status. | The snapshot provably carries every one of these (`report_snapshot_test.dart`) and the renderer consumes only the snapshot. **Not asserted by text extraction** — the `pdf` package compresses content streams, so a byte-level grep would prove nothing. A golden text test would need rendering with compression disabled |
| G3 | ☑ Item photographs are embedded. | `report_renderer_test.dart` ✅ run `33432719089` — a document with a photo is materially larger than the identical one without, so the image bytes demonstrably land in the output |
| G4 | ☑ Multi-page output is produced and correct. | `report_renderer_test.dart` ✅ — 60 items yield more than one `/Type /Page` object; 3 items yield a smaller document |
| G5 | ☐ Output is credible enough to show a client. | No sample PDF committed yet — needs a real generated document in `docs/evidence/` |
| G6 | ☑ Generated bytes are a valid PDF. | `report_renderer_test.dart` ✅ run `33432719089` — output starts `%PDF-` and ends `%%EOF`, for an empty inspection, a populated one, and one with absent optional fields |
| G7 | ☑ A draft cannot produce an official report, and asking for one never submits it. | `report_snapshot_test.dart` ✅ — the loader raises `InspectionNotSubmittedException` and the draft's status is unchanged · `report_flow_test.dart` ✅ — a draft has **no** report action at all |
| G8 | ☑ The report is built from one immutable snapshot, loaded once. | `ReportLoader` reads inspection, profile, items, photo metadata and photo bytes in a single pass; the renderer takes only a `ReportSnapshot` and cannot reach Supabase. Item order is sort_order → created_at → id, asserted deterministic across two loads |
| G9 | ☑ An unfetchable photo aborts generation rather than producing a document with a gap. | `report_snapshot_test.dart` ✅ — raises `ReportPhotoUnavailableException` naming the object; nothing is rendered or shared (`report_flow_test.dart`) |
| G10 | ☑ Progress, failure and share paths are wired and observable. | `report_flow_test.dart` ✅ — renders and shares with a filename derived from the record; render failure and share failure both surface and share nothing; the action returns to idle after a failure |

## H. History and search

| # | Criterion | Evidence |
|---|---|---|
| H1 | ◐ An inspector sees only their own inspections, newest first. | **Isolation ☑** — pgTAP `020` plus hosted smoke assertion 6 (run `33366465489`), so it holds through the app's own client path. **Ordering still ◐**: `newest first` is asserted only in a widget test against a fake; the smoke run creates a single row and cannot prove ordering |
| H2 | ☐ Search matches on site name, address, and client. | Test over the GIN index |
| H3 | ☐ Search returns no other inspector's rows. | pgTAP |

## I. Admin dashboard

| # | Criterion | Evidence |
|---|---|---|
| I1 | ☐ An admin signs in and lists all **submitted** inspections. | Admin test |
| I2 | ☐ An admin opens a submitted inspection and sees its items and photos. | Admin test |
| I3 | ☐ A non-admin signing into the dashboard sees no inspections but their own. | Admin test |
| I6 | ☑ An admin cannot read a `draft` inspection, its items, its photos, or its storage objects — including by direct id. | CI run `d53d066` ✅ |
| I7 | ☑ An admin cannot read the profile of an inspector who has only drafts. | CI run `d53d066` ✅ |
| I4 | ☑ Every admin write attempt is rejected by the database, including creating an inspection of their own. | CI run `d53d066` ✅ |
| I5 | ☐ The service-role key appears in no client bundle. | Grep over `.next` build output — asserted in CI |

## J. Security / RLS

| # | Criterion | Evidence |
|---|---|---|
| J1 | ☑ RLS is enabled **and forced** on all four application tables. | CI run `d53d066` ✅ |
| J2 | ☑ Every cell of the `DATA_MODEL.md` §5 matrix has a passing test. | CI run `d53d066` ✅ |
| J3 | ☑ Inspector A cannot read or mutate inspector B's data at any level of the chain — both the raising and the silent-denial shapes. | CI run `d53d066` ✅ |
| J4 | ☑ No policy grants unrestricted `authenticated` CRUD (no bare `true` qualifier). | CI run `d53d066` ✅ |
| J5 | ☑ No secret is committed. | CI run `d53d066` ✅ |
| J6 | ☑ Cross-user isolation holds through the **app's own authenticated client path**, not only through `psql`. | **Hosted smoke ✅ run `33366465489`** assertions 6–8 against a real hosted project: user B cannot read A's draft (by list or by direct id), cannot update or delete it (verified against the data afterwards, since RLS denies silently), and cannot insert a row owned by A (raises) |
| J7 | ☑ The smoke suite refuses to run under a privileged key. | `_assertNotPrivileged` decodes the JWT and requires `role: anon`, rejecting `sb_secret_` keys — otherwise J6 would pass while proving nothing |

## K. Tests

| # | Criterion | Evidence |
|---|---|---|
| K1 | ☑ `flutter analyze --fatal-infos` reports zero issues. | CI run `606017a` ✅ |
| K2 | ☑ Flutter unit + widget tests pass — **124 tests**, 0 failures. | CI run `33432719089` ✅ |
| K6 | ☑ `dart format --set-exit-if-changed` is clean. | CI run `606017a` ✅ |
| K3 | ☑ pgTAP suite passes against a clean migration run. | CI run `d53d066` ✅ |
| K4 | ☐ Admin lint, typecheck, and tests pass. | CI log |
| K5 | ☑ Tests are deterministic — no ordering dependence, no wall-clock flake. | CI run `d53d066` ✅ |

## L. Builds and release evidence

| # | Criterion | Evidence |
|---|---|---|
| L1 | ☑ Android APK builds in CI and is uploaded as an artifact. | Run `33432719089` ✅ — `app-release.apk` **56.1 MB**, artifact `fieldproof-android-a368d8c…` 26,145,689 bytes |
| L2 | ◐ iOS build verification runs on a macOS runner (no signing required). | **Pending — macOS-only, no execution path.** Passed once on `macos-latest`: run `33351235214`, 1m52s, at `c796b6f`. Not re-verified at HEAD. Moved out of main CI to `.github/workflows/ios.yml`, manual dispatch only (D15) |
| L3 | ☐ The admin production build succeeds. | CI log |
| L4 | ☑ Migrations apply cleanly from empty to head. | CI run `d53d066` ✅ |
| L5 | ☑ CI is green on the default branch. | Run [`33360748640`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33360748640) at `1145a88` — all five main-CI jobs green |

## M. Portfolio evidence

| # | Criterion | Evidence |
|---|---|---|
| M1 | ☐ README documents setup, environment variables, and how to run every gate. | `README.md` |
| M2 | ☐ The end-to-end demo runs: login → new inspection → items → photos → offline → sync → PDF → search → admin. | Recorded walkthrough or ordered screenshots in `docs/evidence/` |
| M3 | ☐ A sample generated PDF is committed. | `docs/evidence/` |
| M4 | ☐ No criterion above is claimed without its named evidence. | This document, fully ☑ |

---

## Known feasibility caveats

- **L2 (iOS):** this machine is macOS 12 with no Xcode installed; current Flutter needs
  Xcode 15+ for iOS builds. iOS verification depends on a GitHub-hosted macOS runner. If
  that proves impractical, L2 is downgraded to an explicitly documented non-goal rather
  than quietly dropped.
- **A1/D1/E1/F1 (integration tests):** these need a live Supabase project (D2). Until one
  exists, they cannot be claimed.

---

## Slice status — Auth → Create Inspection

**Verified (CI `d53d066`, green):** the 17 ☑ criteria above. All are database-level:
migrations, RLS, constraints, admin scoping, determinism, secret hygiene.

**Written but unverified (◐):** every Flutter criterion. `apps/mobile` has not yet been
through CI — this slice is the first commit containing it, so `flutter analyze`,
`flutter test` and the APK build have never run. No Flutter toolchain exists on the
development machine (D1), so none of it could be run locally either.

**Two limits worth stating plainly:**

1. The Flutter tests exercise the client contract against in-memory fakes. They prove the
   app sends the right payload, surfaces errors instead of swallowing them, and never lets
   a caller name the owner. They prove **nothing** about RLS — that is what the pgTAP suite
   is for, and the fakes deliberately do not re-implement policy checks, because a fake
   that enforced RLS would be testing itself.
2. No live Supabase project is configured, so the authenticated round trip
   (sign in → insert → read back) has never executed against a real database. B1 and the
   A-series cannot be claimed until it has.

---

## CI verification status — run `33358859631` (self-hosted T410s)

Every gate in the main CI workflow, green:

| Gate | Result |
|---|---|
| Detect slices | ✅ 17s |
| Secret hygiene | ✅ 16s |
| **Database + RLS** | ✅ **1m26s** |
| `dart format --set-exit-if-changed` | ✅ |
| `flutter analyze --fatal-infos` | ✅ zero issues |
| `flutter test` | ✅ **28 passed, 0 failed** |
| Generate Android scaffolding | ✅ |
| **Build release APK** | ✅ `app-release.apk` **49.1 MB** (Gradle 1263.5s, cold) |
| Upload artifact | ✅ `fieldproof-android-ec9e5e3…`, 23,170,151 bytes |

Mobile job total: **27m23s** (cold Gradle). Warm builds reuse `~/.gradle`.

**iOS is not in this table** — it is a separate, manual-only workflow with no
macOS execution path. See L2 and D15. It is not emulated and not marked passed.

### How each failure was actually fixed

No gate was weakened, skipped, or made non-blocking at any point. In order:

| Failure | Real cause | Fix |
|---|---|---|
| `dart format` | formatter unavailable locally (Dart 3.13 needs macOS 14) | CI emits the patch as an artifact; applied verbatim |
| `flutter analyze` | 5 genuine findings | fixed the code — deprecated `anonKey`, `minSize`, missing braces |
| `010` pgTAP assertion | contradicted the `NOT is_admin()` guard it was meant to protect | rewrote the assertion |
| Database disk guard | root filesystem genuinely short | reclaimed 126 GB of unused NTFS; kept `MIN_FREE_GB` at 5 |
| APK — no SDK | Android SDK absent | installed it, exported via the runner's `.env` |
| APK — worker killed, no logs | root hit 100% mid-build | moved `~/.gradle` and `_work` onto the 126 GB volume |
| APK — `Permission denied` on Gradle lock | `/data` was `0710`, inherited from Docker's hardened data root | `chmod 755 /data` |

### Confirmation run — `33360748640` at `1145a88`

The first fully green run of the main CI workflow, after the iOS split:

| Job | Result |
|---|---|
| Detect slices | ✅ 17s |
| Secret hygiene | ✅ 17s |
| Database + RLS | ✅ 1m31s |
| Mobile (Flutter) | ✅ **15m59s** |
| Admin (Next.js) | skipped — slice does not exist yet |

**run: completed/success.** Artifact `fieldproof-android-1145a88…`, 23,170,144 bytes.

Mobile fell from **27m23s to 15m59s** between the two runs with no code change —
the warm `~/.gradle` on the 126 GB volume, which is the whole argument for D16.

---

## Slice complete — Auth → Create Inspection

**Status: complete.** UI → auth → database → RLS → tests, evidenced end to end
against a real hosted Supabase project.

| Layer | Evidence |
|---|---|
| UI | Cupertino sign-in and New Inspection sheet, matching the approved Figma direction (D14). 28 widget/unit tests |
| Auth | Hosted smoke assertion 1 — real Supabase Auth, real JWT (A1) |
| Profile bootstrap | Assertion 2 — `on_auth_user_created` trigger, role `inspector` (A2) |
| Database | Assertions 3–5 — created via `SupabaseInspectionsRepository`, read back, `inspector_id` re-read from the server (B1) |
| RLS | pgTAP `010`–`050`, plus assertions 6–8 through the app's own client path (J1–J7) |
| Tests | 28 hermetic + 8 hosted, all green (K1, K2, K3, K5, K6) |
| Build | Android APK in CI with artifact (L1); CI green on the default branch (L5) |

**Runs:** full CI `33369532564` (all jobs green) · hosted smoke `33366465489`
(8/8) · standalone smoke `33369533628` (8/8, no APK rebuild).

### Two sub-criteria deliberately left in progress

Marking the slice complete does not mean every line above is ☑, and these two
are not:

- **A3** — sign-out routing is proven by widget test, but the hosted smoke calls
  `signOut()` in teardown without asserting on it, so real session teardown is
  unverified.
- **H1 (ordering)** — "only their own" is proven end to end; "newest first" is
  not. The smoke run creates a single row, so it cannot demonstrate ordering.

Both are honest gaps in an otherwise complete slice, not blockers for the next
one. Neither is claimed as evidence anywhere.

### Not part of this slice

Photos, PDF, offline drafts, sync, search, and the admin dashboard are later
slices and remain ☐. iOS verification is pending and macOS-only (L2, D15).

---

## Slice complete — Inspection Detail → Punch Item CRUD

**Status: complete.** Detail screen, add/edit/delete/resolve/reopen, persisted
through the ordinary authenticated client, evidenced against a real project.

**Run [`33375863716`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33375863716)
at `7d1fdf5` — every job green:**

| Gate | Result |
|---|---|
| Secret hygiene | ✅ 16s |
| Detect slices | ✅ 16s |
| Mobile (Flutter) | ✅ 16m47s — format, analyze, **63 tests**, APK **50.1 MB** |
| Database + RLS | ✅ 1m34s — pgTAP `010`–`060` |
| Hosted Supabase smoke | ✅ 7m13s — **15/15** |

### Contract decisions this slice exercised

| Question | Resolution |
|---|---|
| Severity vocabulary | Schema's `low\|medium\|high\|critical`. The mockup's `minor\|major\|critical` is rejected by the client *and* by Postgres (`22P02`) |
| Punch status | Schema's `open\|resolved`. `in-review` rejected the same way |
| Resolve/reopen | Bidirectional. The one-way trigger is on `inspections.status` (D10), not on items — asserted in both directions |
| Submitted inspections | Items stay editable. `inspection_items_update_own` gates on ownership only, and D10 records that locking submitted content was considered and not adopted. A UI-only lock would be theatre |
| Figma-only fields | `assignee`, `template`, `organisation` absent. `item_models_test` asserts the insert payload carries exactly the six schema keys |

### Deliberate boundaries

- The Flutter fake enforces **no** ownership rule. A fake that re-implemented
  RLS would only test itself; isolation is proven by pgTAP `060` and the hosted
  smoke run.
- `SupabaseInspectionItemsRepository` raises `NotPermittedException` when an
  update or delete matches zero rows, because that is how RLS denies — silently.
  Reporting it as success is the exact failure `020`/`060` test for.
- **C2 (reordering) is not implemented** and stays ☐. `sort_order` is assigned on
  append only.

---

## Integrity gate complete — submitted inspections are immutable (D17)

**Run [`33384740243`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33384740243) — every job green.**

| Gate | Result |
|---|---|
| Detect slices · Secret hygiene | ✅ |
| Database + RLS | ✅ pgTAP `010`–`070` |
| Mobile (Flutter) | ✅ **67 tests**, APK **50.1 MB** |
| Hosted Supabase smoke | ✅ 15/15 |

Enforced in `20260831000500_submitted_immutable.sql`, **in the database**. Every
write policy on `inspections`, `inspection_items`, `item_photos` and the storage
bucket now requires the governing inspection to be `draft`.

### What `070` actually proves

| | |
|---|---|
| Still readable | owner reads the submitted inspection, its 2 items, its photo |
| Inspection frozen | edit and delete both deny silently; data re-read unchanged |
| Items frozen | INSERT raises `42501`; edit, resolve and delete deny silently |
| Photos frozen | INSERT raises `42501`; delete denies silently |
| Drafts unaffected | edit applies, item adds, **and the draft can still be submitted** |
| Immediate | the freshly submitted inspection is frozen from that moment |
| Admin unchanged | D3 still holds — admins still read submitted work |

The draft-unaffected cases matter as much as the frozen ones: a gate that also
froze drafts would make the app unusable, and those assertions would catch it.

### Two existing tests had to change, and why

Neither was weakened — both were asserting something that is no longer the
mechanism:

- **`050` un-submit** expected D10's trigger exception (`23514`). RLS now refuses
  first, so the update matches zero rows and raises nothing. The assertion is now
  about the resulting data, which is the stronger claim anyway.
- **`050` composite FK (D8)** proved the key by claiming a *submitted* inspection.
  D17 refuses that with `42501` before the FK is consulted, so the test had stopped
  testing what it named. Split in two: the cross-owner case asserts the RLS refusal
  it really triggers, and a new case proves the FK using two drafts the caller owns,
  where only the key can reject it.

---

## Slice complete — Photos

**Status: complete.** Attach → private Storage → metadata → display → delete,
evidenced against a real hosted Supabase project.

**Run [`33403013321`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33403013321) at `98b3b1f` — every job green:**

| Gate | Result |
|---|---|
| Detect slices · Secret hygiene | ✅ |
| Mobile (Flutter) | ✅ 19m42s — format 0 changed, analyze **no issues**, **92 tests**, APK **51.0 MB** |
| Database + RLS | ✅ 1m41s — pgTAP `010`–`080` |
| Hosted Supabase smoke | ✅ 8m01s — **23/23** |

Artifact `fieldproof-android-98b3b1f…`, 23,940,248 bytes.

### Ownership is enforced twice, and both halves are proven

A photo is only safe if the metadata row *and* the object agree. Either alone
would be a hole:

| | Metadata (`item_photos`) | Storage object |
|---|---|---|
| Owner | via parent inspection — pgTAP `060` | path segment `[1]` vs `auth.uid()` — pgTAP `080` |
| Draft-only | pgTAP `070` | pgTAP `080` |
| Cross-owner | hosted smoke 19 | hosted smoke 19–20 |

### Failure integrity (D19)

Upload is object→metadata with a compensating object delete; delete is
metadata→object with `PhotoCleanupException` and no resurrection of the row.
`photo_workflow_test.dart` forces both failure modes directly — that is what the
two ports exist for, and it is the reason the ordering is evidence rather than
intention.

### Boundaries kept

No image editing, annotation, backend thumbnails, CDN work, photo reordering,
offline queue, or PDF. The whole "compression pipeline" is a capture-time size
cap (2048px, quality 85) so a phone photo does not arrive at 8 MB and get
rejected after the user has waited for it.

### Not covered by any automated test

Real camera capture. `image_picker` sits behind `PhotoSource` so the widget
tests drive a fake; capture on a physical device is Android build/device
evidence (D20), and no host-side test can stand in for it.

### One thing this slice caught that was not about photos

Hosted smoke cases 22–23 failed initially because migration
`20260831000500_submitted_immutable.sql` had never been applied to the hosted
project — D17 was enforced in CI but not in the live database. `supabase db push`
fixed it, and those two cases are now a permanent schema-drift detector: any
future migration that is not pushed fails here rather than passing unnoticed.

---

## Slice complete — PDF report

**Status: complete.** `submitted inspection → immutable ReportSnapshot → PDF →
preview/share/save`.

**Run [`33432719089`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33432719089) — every job green:**

| Gate | Result |
|---|---|
| Detect slices · Secret hygiene | ✅ |
| Mobile (Flutter) | ✅ 18m07s — format clean, analyze **no issues**, **124 tests**, APK **56.1 MB** |
| Database + RLS | ✅ 1m38s — pgTAP `010`–`080` unchanged |
| Hosted Supabase smoke | ✅ 8m50s — 23/23 unchanged |

Artifact `fieldproof-android-a368d8c…`, 26,145,689 bytes. Tests 92 → **124**.

### Shape

`ReportLoader` reads the inspection, profile, items, photo metadata and photo
bytes in **one pass**; `PdfReportRenderer` takes only a `ReportSnapshot` and has
no way to reach Supabase; `ReportSharer` is the only thing that touches
`printing`. That last boundary is why every widget test runs without a platform
channel, and the first is why a document cannot end up with a header from one
moment and a body from another.

### Nothing is persisted

No report table, no uploaded PDF, no editable report content (D21). The database
stays the single source of truth and regeneration reproduces the current
submitted record. Under D17 that record cannot change, so a stored copy would add
staleness risk in exchange for nothing.

### Deliberately not claimed

Three criteria are **not** marked met, and the reasons are worth stating rather
than rounding up:

- **G1** — rendering is genuinely offline, but loading the snapshot is not. True
  offline generation belongs to the offline slice.
- **G2** — the snapshot provably carries every printed field, but no test extracts
  text from the PDF. The `pdf` package compresses content streams, so a byte grep
  would prove nothing; a real golden test needs rendering with compression off.
- **G5** — no sample PDF is committed to `docs/evidence/` yet.

### Contract changed mid-slice

An unfetchable photo originally rendered "Photograph unavailable" in place. That
was withdrawn in favour of aborting generation (D21): a document that shows a
placeholder where evidence should be still reads as complete to whoever receives
it. One transient fetch failure now blocks the whole report — the accepted cost
of a document that is either complete or absent.
