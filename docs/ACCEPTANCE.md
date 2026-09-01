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
E1 was written as one criterion covering the draft, its items **and** its photos. It is
split, because only the first two are built: **E1a** closes here; **E1b** (offline photo
capture) is deferred with its reason recorded in D27, not quietly dropped.

| # | Criterion | Evidence |
|---|---|---|
| E1a | ☐ With the server unreachable, an inspector creates a draft inspection and adds, edits and deletes its punch items. | `offline_flow_test.dart` — the same New Inspection sheet and the same punch-list editor, driven through the widget tree with the remote repository failing · `offline_sync_test.dart` covers add/edit/delete at the repository |
| E1b | ☐ **Deferred, not done.** The same, with photos. | Needs a durable local file store (`path_provider`), deterministic photo ids so a retry cannot duplicate a Storage object, and local-file rendering in the photo strip. D27 records why it is its own slice |
| E2 | ☐ A local draft survives an app restart. | `offline_flow_test.dart` tears the widget tree down and rebuilds every stateful object over the same stored bytes · `offline_store_test.dart` reconstructs the queue from bytes alone, and round-trips through the real `shared_preferences` implementation |
| E3 | ☐ No local change is discarded without an explicit user action. | `offline_sync_test.dart` — a failed push keeps the draft *and* its items, with the reason attached, across reconstruction; a failed write surfaces rather than reporting a save that did not happen; the local record is removed in exactly one place, after the server has been read back |
| E4 | ☐ Draft state is visibly distinguishable from synced state in the UI. | A `Not synced` pill beside `Draft`, and the offline banner — both asserted in `offline_flow_test.dart`. Screenshot from real-device QA |

## F. Synchronization

| # | Criterion | Evidence |
|---|---|---|
| F1 | ☐ On reconnect, pending drafts push to Supabase and are marked synced. | `offline_flow_test.dart` — Retry, and reopening the app, both push the queue and clear the marker · hosted smoke case 30 pushes an offline-origin draft to the real project through the production `SupabaseDraftSink`. "Marked synced" is a **deletion**, not a flag (D27) |
| F2 | ☐ Sync is idempotent — running it twice produces no duplicate rows. | pgTAP `050` at the database level, now covering the merge-upsert the client actually sends as well as `DO NOTHING` · `offline_sync_test.dart` at the repository · **hosted smoke case 33** replays the push against real Supabase and asserts one inspection and two items |
| F3 | ☐ An interrupted sync resumes without data loss or duplication. | `offline_sync_test.dart` — the parent lands, the items fail, the retry produces one of each; an item deleted locally between attempts is pruned from the server; a write that reports success but cannot be read back is treated as a failure, because RLS refuses silently |
| F4 | ☐ Sync failures surface to the user; they are never swallowed. | `offline_flow_test.dart` renders the underlying error verbatim in the banner and keeps the draft · `offline_sync_test.dart` asserts the status carries it |
| F5 | ☐ An unsynced draft cannot be submitted, and never looks submitted. | `offline_sync_test.dart` — `submit` raises `DraftNotSyncedException` and the record stays a local draft · `offline_flow_test.dart` — the Submit control is absent and the reason is shown · `offline_store_test.dart` — a local record has no code path to `submitted` |
| F6 | ☐ Ownership survives the queue: it comes from the session and RLS, never from stored bytes. | `offline_sync_test.dart` — no session pushes nothing and loses nothing; a different session does not push another inspector's work · **hosted smoke case 35** — user B's queue holding A's id is refused by real RLS, and A's row is unchanged · pgTAP `050` — a merge cannot reassign `inspector_id` or land on another inspector's row |

## G. PDF

| # | Criterion | Evidence |
|---|---|---|
| G1 | ◐ A PDF generates on-device with no network connection. | **Rendering is offline** — `PdfReportRenderer` is pure, takes a snapshot and returns bytes, and `report_renderer_test.dart` runs it with no network at all. **Loading the snapshot still needs the network.** This was recorded as belonging to the offline slice; it does not, and the earlier note was wrong. A report requires a *submitted* inspection (D21), and a submitted inspection is by definition server-backed — so offline generation would mean caching server records on the device, which D24 and D5 exclude. It stays ◐ and belongs to a caching slice that has not been scoped |
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
| H1 | ☑ An inspector sees only their own inspections, newest first, in a deterministic order. | **Isolation** — pgTAP `020` plus hosted smoke assertions 6–8. **Ordering** — hosted smoke **case 25** (run `33446869242`) creates two rows dated 2020-06-01 and 2020-01-01 through the app's own client and asserts the newer precedes the older, then walks the whole list asserting it never ascends, so ordering is a property of the query and not of two rows. pgTAP `090` asserts the same `inspection_date DESC` over seeded data. **Determinism** — the order is total: `search_test.dart` seeds three rows sharing one date with no timestamps and asserts two successive calls return the identical sequence, which the `created_at DESC, id DESC` tiebreak is what makes true; pgTAP `090` inserts two same-date rows in one transaction and asserts the id tiebreak resolves them |
| H2 | ☑ Search matches on site name, address, and client. | pgTAP `090` — separate assertions for site (`northgate:*`), address (`dock:*`) and client (`meridian:*`) against the stored `search_tsv` and its GIN index, plus case-insensitivity, prefix matching, and both lifecycle states searchable. Hosted smoke **case 26** proves all three field kinds end to end against the real project, and **case 27** case-insensitivity and prefix. Client side, `search_test.dart` pins the tsquery the app sends (terms lowercased, ANDed, each `:*`-suffixed, tsquery operators in user input neutralised) and `search_flow_test.dart` drives it through the widget tree |
| H3 | ☑ Search returns no other inspector's rows. | pgTAP `090` — B's inspection carries three terms appearing nowhere in A's rows (`riverside`, `ashcroft`, `sheffield`); A searching each finds nothing, B searching A's unique term finds nothing, and no query returns a row whose `inspector_id` is not the caller's. `anon` is refused `42501`, so search is not a way around the unauthenticated denial. Hosted smoke **case 28** proves it both directions against the real project using per-run unique tokens, so a stale fixture cannot make it pass. Search is an ordinary `SELECT`, so this is RLS doing the work — the client sends no `inspector_id` |

## I. Admin dashboard

| # | Criterion | Evidence |
|---|---|---|
| I1 | ☑ An admin signs in and lists all **submitted** inspections. | Run `33453238838` ✅. `render.test.tsx` asserts the queue renders site, address, client, inspector name, inspection date, submitted timestamp and status, and one row per inspection. `repository.test.ts` asserts the query carries `eq(status, submitted)` and the D22 ordering (`inspection_date DESC, created_at DESC, id DESC`). Sign-in is ordinary Supabase auth with the publishable key and the console holds no privileged credential, so pgTAP `030` is what makes the list submitted-only |
| I2 | ☑ An admin opens a submitted inspection and sees its items and photos. | Run `33453238838` ✅ — `render.test.tsx` asserts title, description, area, severity and open/resolved state per item, and photos rendered through their signed URL. The bucket stays private (D19): each URL is minted per request against the reviewer's own session, so storage RLS decides whether it is issued at all. A photo that cannot be signed is stated rather than omitted, so an incomplete record does not read as a complete one |
| I3 | ☑ A non-admin signing into the dashboard is refused outright. | Run `33453238838` ✅ — **met more strictly than worded.** `access.test.ts` asserts an authenticated inspector resolves to `forbidden` and never reaches the console, so what they would see does not arise; RLS would in any case return only their own rows. It fails closed on a missing profile, an absent role, an unknown role, and the `Admin`/`not-admin` near-misses — a transient profile read must not become an authorisation bypass. pgTAP `020` proves the database half: an inspector cannot read another inspector's **submitted** row, named by id |
| I6 | ☑ An admin cannot read a `draft` inspection, its items, its photos, or its storage objects — including by direct id. | CI run `d53d066` ✅ |
| I7 | ☑ An admin cannot read the profile of an inspector who has only drafts. | CI run `d53d066` ✅ |
| I4 | ☑ Every admin write attempt is rejected by the database, including creating an inspection of their own, and including photo metadata. | Run `33453238838` ✅ — pgTAP `030`. `INSERT` on `inspections`, `inspection_items` and `item_photos` all raise `42501`. `UPDATE`/`DELETE` fail `USING` and are therefore **silent**, so each is followed by a privileged re-read proving the site name, the row count, the item severity, the photo row and its caption are all unchanged. The photo-metadata cases were added with the admin console: an admin who could add or remove a photo on the record they are reviewing would not be read-only in any sense that matters |
| I5 | ☑ No privileged key appears in any client bundle. | Run `33453238838` ✅ — CI greps the built `.next/static` and reports `Client bundle clean.` Belt and braces: `src/lib/env.ts` refuses to start unless the key is positively identifiable as publishable (an anon JWT or `sb_publishable_`) — an allowlist, not a denylist — asserted in `env.test.ts` |

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
| K2 | ☑ Flutter unit + widget tests pass — **153 tests**, 0 failures. | CI run `33446869242` ✅ |
| K6 | ☑ `dart format --set-exit-if-changed` is clean. | CI run `606017a` ✅ |
| K3 | ☑ pgTAP suite passes against a clean migration run — **174 assertions**, 9 files. | Run `33453238838` ✅ — `Files=9, Tests=174`, `Result: PASS`, run twice (unseeded apply, then seeded re-apply) |
| K4 | ☑ Admin lint, typecheck, and tests pass — **36 tests**, 0 failures. | Run `33453238838` ✅ — `✔ No ESLint warnings or errors`, `tsc --noEmit` clean, vitest 36/36 across 5 files |
| K5 | ☑ Tests are deterministic — no ordering dependence, no wall-clock flake. | CI run `d53d066` ✅ |

## L. Builds and release evidence

| # | Criterion | Evidence |
|---|---|---|
| L1 | ☑ Android APK builds in CI and is uploaded as an artifact. | Run `33446869242` ✅ — `app-release.apk` **56.2 MB**, artifact `fieldproof-android-656dfbb…` 26,170,704 bytes |
| L2 | ◐ iOS build verification runs on a macOS runner (no signing required). | **Pending — macOS-only, no execution path.** Passed once on `macos-latest`: run `33351235214`, 1m52s, at `c796b6f`. Not re-verified at HEAD. Moved out of main CI to `.github/workflows/ios.yml`, manual dispatch only (D15) |
| L3 | ☑ The admin production build succeeds. | Run `33453238838` ✅ — `✓ Compiled successfully`, 7 routes, 87.2 kB shared JS. `/inspections` and `/inspections/[id]` build as `ƒ` (server-rendered on demand), so no page is prerendered holding inspection data. Vercel-compatible; not deployed, since deployment is not part of the accepted workflow |
| L4 | ☑ Migrations apply cleanly from empty to head. | CI run `d53d066` ✅ |
| L5 | ☑ CI is green on the default branch. | Run [`33360748640`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33360748640) at `1145a88` — all five main-CI jobs green |
| L6 | ☑ Real-device QA on Android hardware. | **Complete — see "Real-device QA" below.** Executed across two Android devices (Redmi Note 10 Pro / **SDK 30**, Raspberry Pi 4 running Android 16 / **SDK 36**) against the hosted project, plus the production Admin build in Chrome 150. Every acceptance step was performed and verified from a screenshot or a live DOM query; none is inferred from CI. This gate found and closed a real defect — the app had no submit action at all (see the defect record below) |

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
- **H1 (ordering)** — *closed by the search slice.* Hosted smoke case 25 now
  creates two rows with known, different dates and asserts the order through the
  app's own client; see H1 above.

A3 remains an honest gap in an otherwise complete slice, not a blocker for the
next one. It is not claimed as evidence anywhere.

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

---

## Slice complete — Inspection History → Search → deterministic ordering

**Status: complete.** Run
[`33446869242`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33446869242)
at `656dfbb` — one run, every gate green:

| Gate | Result |
|---|---|
| Formatting | ✅ `Formatted 35 files (0 changed)` |
| Analyze | ✅ `No issues found!` (`--fatal-infos`) |
| Flutter tests | ✅ **153 passed**, 0 failed |
| Android release APK | ✅ 56.2 MB, artifact `fieldproof-android-656dfbb…` (26,170,704 bytes) |
| Database + RLS | ✅ pgTAP `010`–`090`, Files=9 Tests=165, `Result: PASS` |
| Hosted Supabase smoke | ✅ **29/29**, including cases 24–29 |

### Search runs in the database, not in the client

`InspectionsRepository` gained `searchMine`, and one private `_query` builds both
history and search, so the two cannot drift in ordering or in column selection. A
query becomes a `textSearch` against the stored `search_tsv` and its existing GIN
index — no migration was added, because `inspections_search_idx` was already
there from the initial schema. Nothing is fetched-then-filtered, and the client
sends no `inspector_id`: ownership stays RLS's job, which is what makes H3
provable rather than asserted.

### The ordering is total, not merely descending

`inspection_date DESC, created_at DESC, id DESC`. The final key is the point:
two inspections created on the same date in one transaction would otherwise come
back in either order between calls. pgTAP `090` inserts exactly that pair and
asserts the tiebreak resolves it; `search_test.dart` asserts two successive calls
return the identical sequence.

### Staleness is handled by a token, not a framework

Each load takes the next value of a monotonic counter and applies its result only
if it is still the newest. Two widget tests cover it, including the sharper case
where the *stale* query matches more rows than the current one — the case a
naive test misses, because there the stale response would visibly resurrect
filtered-out rows rather than merely flicker.

### What the existing tests caught

Adding the search box broke four assertions in `app_flow_test.dart`.
`CupertinoSearchTextField` builds a `CupertinoTextField`, and the inspections
screen stays mounted beneath the modal sheet, so an unscoped
`find.byType(CupertinoTextField)` went from three matches to four and `.at(0)`
became the search box. The fix scoped those finders to `NewInspectionSheet`,
which strengthens the assertion — "the sheet offers exactly the schema fields"
now asserts what its comment always claimed. Relaxing the count to four was the
available weakening fix and was not taken.

### Not part of this slice

Offline drafts and sync, real-device QA, and the admin dashboard remain ☐.

---

## Slice complete — Admin review console

**Status: complete.** Run
[`33453238838`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33453238838)
at `bcf41ee` — one run, every gate green, nothing weakened to get there:

| Gate | Result |
|---|---|
| Admin (Next.js) | ✅ lint clean, `tsc` clean, **36 tests**, production build, `Client bundle clean.` |
| Database + RLS | ✅ pgTAP `010`–`090`, **Files=9 Tests=174**, `Result: PASS` |
| Mobile (Flutter) | ✅ format 0 changed, analyze clean, **153 tests**, APK 56.2 MB |
| Hosted Supabase smoke | ✅ **29/29** |
| Secret hygiene | ✅ |

APK artifact `fieldproof-android-bcf41ee…`, 26,170,705 bytes.

### No migration was needed, and that was the finding

The policies written for D3 already satisfied the accepted admin contract: `SELECT` only,
scoped to `status = 'submitted'`, with no admin write policy of any kind and
`and not public.is_admin()` on the ownership write policies. What was missing was two
*assertions*, not two policies, and both are now in the suite:

- **`030`** — an admin adding or removing photo **metadata**. The file read `item_photos`
  but had never attempted to write it. `INSERT` raises `42501`; `UPDATE` and `DELETE` fail
  `USING` and are therefore silent, so both are followed by a privileged re-read.
- **`020`** — an ordinary inspector reading another inspector's **submitted** row, named
  directly by id rather than inferred from a count, along with its items, its photo
  metadata and the submitting inspector's profile. Submitting is what makes work
  reviewable, not public — a distinction that only becomes testable once a console exists.

### The console adds no privilege

It signs in as an ordinary user, holds only the publishable key, and every query runs as
the reviewer's own session, so the admin policies are the authority rather than a
convention the UI agrees to follow (D23). `resolveAccess` is an authorisation gate on top
of that, not a substitute for it: without it an inspector reaching `/inspections` would get
a working console listing their *own* submitted work — not a leak, but not a review console
either. Remove the gate and nothing leaks; remove RLS and everything does.

### Read-only is asserted, not intended

`AdminRepository` has no write method, and a test renders the detail view and fails if it
contains a `button`, `form`, `input`, `select` or `textarea`. A control the database would
refuse is still a lie told to the reviewer.

### One search, one index, one ordering

The console mirrors the Flutter client's tsquery construction against the same stored
`search_tsv` and its existing GIN index — no second index and no second semantics — and
reuses D22's total order. `test/search.test.ts` pins the cases the Dart tests pin, because
two clients querying one column must not disagree about what a word matches. Search is a
GET form, so the query lives in the URL and no client state library is involved.

### Not part of this slice

No server-side PDF (D21 — the Flutter client remains the only thing that generates a
document, and nothing is persisted). No admin CRUD, user or role management, analytics,
charts, audit-log UI, revision UI, comments or approvals. Real-device QA (L2) and offline
sync remain ☐.

---

## Real-device QA — in progress, **L2 remains open**

Hardware: **Redmi Note 10 Pro (M2101K6G), Android 11 (SDK 30), 1080×2400 @ 440dpi**, against
the real hosted Supabase project. Evidence below is separated by how it was obtained,
because automated coverage is not a substitute for an unexecuted hardware step.

### Defect found and fixed by this QA gate — the app could not submit

**This is the finding that justifies the gate.** Every CI gate was green and the database
enforced `draft → submitted` correctly, but the Flutter application had **no user-accessible
submit operation**: `InspectionsRepository` exposed `create`, `listMine` and `searchMine`
only, and no screen offered the action. The accepted V1 workflow was therefore not
completable by a person holding the phone.

It survived every automated layer because the *test* reached around the client:
`hosted_smoke_test.dart` submitted with a raw
`.update({'status': 'submitted'})` on the Supabase client, proving only that Postgres would
allow the transition. pgTAP `050` and `070` were likewise correct and likewise blind to it —
they test the database, and the database was never the problem.

| Evidence | |
|---|---|
| Missing before QA | No `submit()` on the repository; no submit control on any screen |
| Fix | [`278e7d7`](https://github.com/huyupwork-hub/upwork-system/commit/278e7d7) — repository method, confirmation-gated UI, 9 widget tests, list reload on return |
| Formatting follow-up | [`eebcb2e`](https://github.com/huyupwork-hub/upwork-system/commit/eebcb2e) |
| Smoke no longer bypasses the client | case 22 calls `inspectionsA.submit(...)` and asserts a second submit is refused |
| CI | Run [`33465140822`](https://github.com/huyupwork-hub/upwork-system/actions/runs/33465140822) — all six gates green, 162 Flutter tests |
| Executed on hardware | Submit performed through the real Flutter UI on the Redmi |

No migration and no new pgTAP were needed: `050` already proved the transition and the
`submitted_at` stamp, `070` the immutability that follows. The gap was purely the client, so
that is the only layer that changed.

### Proven on real Redmi hardware

Executed on the device, each verified from a screenshot:

| # | Step | Evidence |
|---|---|---|
| 1 | APK installs and launches | Artifact `fieldproof-android-eebcb2e…`, sha256 `01a1e535…` |
| 2 | No sign-up path exists (D13) | Sign-in screen offers email/password only |
| 3 | Empty-field validation | "Enter your email and password." |
| 4 | Bad credentials refused | Real GoTrue "Invalid login credentials", no navigation |
| 5 | Sign in as inspector | Reaches the history list |
| 6 | History renders and orders | Same-date rows descend by `created_at` (D22) |
| 7 | Create inspection | Exactly Name/Address/Client; no Template picker; Date and Inspector read-only (D14) |
| 8 | Add punch item | Severity exactly `Low\|Medium\|High\|Critical`; binary Resolved toggle (D14) |
| 9 | Real camera photo | Capture → Storage upload → metadata insert → signed-URL thumbnail, private bucket |
| 10 | Picker cancelled is not a failure | Returns with no photo and no error |
| 11 | **Submit through the Flutter UI** | Confirmation naming both consequences, then status → Submitted |
| 12 | Post-submit immutability | Lock notice; submit control gone; `+` replaced by report icon; item row loses its chevron |
| 13 | List reflects the new status | Row reads `Submitted` on return |
| 14 | Auth session survives app restart | Relaunch went straight to the list |

The record created and submitted on hardware is **`Device QA Northgate Depot`**
(2026-09-01, 17 Harbour Way Leeds, Redmi QA Client, one `Critical` item "Exposed wiring at
junction box" in Plant room, one camera photo).

### Proven against the production Admin build

`next start` on the production build, hosted Supabase, no authenticated session:

| Check | Evidence |
|---|---|
| `/inspections` signed out | 307 → `/sign-in` |
| `/inspections/<id>` signed out | 307 → `/sign-in` — a guessed id does not bypass the gate |
| `/` signed out | 307 |
| `/no-access` reachable | 200 |
| Sign-in page carries no inspection data | 0 references to any record |
| Production emits its stylesheet | `static/css/…` 5,084 bytes, containing the real tokens |

### Proven on the Raspberry Pi 4 — Android 16 (SDK 36)

A second Android target, deliberately recorded separately from the Redmi rows.
It is real Android on real hardware, not an emulator, but it is not the phone —
and the real-camera capture stays Redmi evidence, since a Pi has no camera.

Its value is version coverage the Redmi cannot give: **SDK 30 vs SDK 36**, six
Android releases apart, from the same APK.

| # | Step | Evidence |
|---|---|---|
| 15 | Install and launch on SDK 36 | Same artifact `fieldproof-android-eebcb2e…` |
| 16 | Sign in; the record created on the Redmi appears | Cross-device data consistency for the same account |
| 17 | **Search by site** | `Northgate` → exactly 1 result, no duplicates |
| 18 | **Search by address** | `Harbour Way` (two terms, ANDed) → exactly 1 |
| 19 | **Search by client** | `Redmi QA Client` (three terms) → exactly 1 |
| 20 | Submitted detail is read-only | Lock notice; no add/edit/submit; item row has no chevron |
| 21 | **PDF generates and opens on Android** | Share sheet offers `fieldproof-device-qa-northgate-depot-20260901-55010928.pdf`; Android print preview **renders the document** |
| 22 | PDF content matches the record | FieldProof header; site, address, client, **inspector `fieldproof-smoke-a`**, **submitted 2026-09-01 03:35 UTC**, inspection id; summary 1 item / 1 open / 1 photo / 1 critical; punch item with **Critical · Open**, `Plant room`, full description; **the Redmi camera photo rendered in place** |
| 23 | **Populated draft survives process death** | `Device QA Persistence 123726` + one `High` item in `Boiler room`; `am force-stop` verified by PID (2236 → gone); relaunch as PID 3481 |
| 24 | …with no duplication and no re-login | Exactly one inspection row and one item afterwards; session still valid; still `Draft`, still editable |
| 25 | Sign out works on device | Returns to the sign-in screen with fields cleared |
| 26 | **Inspector B cannot see A's submitted work** | Signed in as user B: "No inspections yet."; searching `Northgate` → "No inspections match" — RLS holding through the app's own client path |

### Proven in the production Admin console — Chrome 150

Authenticated as the admin account against `next start` on the production build
and the hosted project. Verified by live DOM queries, not HTML string matching.

| Check | Evidence |
|---|---|
| Admin signs in and lists submitted work | Lands on `/inspections`, **22 rows** |
| The QA record appears **exactly once** | 1 occurrence of `Device QA Northgate Depot` |
| Inspector / client / address / date | `fieldproof-smoke-a` · Redmi QA Client · 17 Harbour Way, Leeds · 1 Sep 2026 |
| Submitted timestamp | **1 Sep 2026, 03:35 UTC** — identical to the PDF and the device |
| **Drafts are invisible to the admin** | 0 occurrences of `Persistence` and 0 of `Draft`, while that draft demonstrably exists for its owner (D3) |
| Search locates it | `?q=Harbour Way` → 1 row, 0 SMOKE rows |
| Detail opens with full fidelity | Critical · Open · `Plant room` · "Cover plate missing - conductors visible"; "1 total, 1 open" |
| Private photo renders | 1 image from `…supabase.co` with a signing token, **actually decoded at 1536×2048** — a broken URL would report 0×0 |
| **No mutation controls anywhere** | `button: 0, form: 0, input: 0, select: 0, textarea: 0` on the detail page |

### Environment observation — not a product defect

The console fails with "Application error: a client-side exception has occurred"
in **LineageOS Jelly on AOSP WebView** (the Pi's only browser). The same build,
the same account and the same server succeed in **Chrome 150**, and the admin
credentials and `role = admin` were independently confirmed against Supabase, so
this is an engine limitation of a stripped-down WebView rather than a fault in
the console. The console's accepted design targets desktop browsers; AOSP WebView
is not a target. Recorded rather than fixed, because nothing in the accepted
contract is violated.

### Maintenance finding — hosted smoke residue

The hosted project holds 11+ `SMOKE … do-not-keep` submitted rows. Each smoke run submits an
inspection to exercise D17, and D17 then correctly forbids its owner from ever deleting it.
This is the immutability contract working, not a defect. Recorded as follow-up: any fix must
preserve D17 — no admin delete, no unsubmit, no privileged cleanup from the application.
