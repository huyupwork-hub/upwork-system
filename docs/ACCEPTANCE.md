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
| A1 | ◐ An existing user signs in with email + password. **Sign-up is out of V1 scope (D13)** — accounts come from the dashboard or seed. | Widget test ✅ run `606017a`, but against a **fake** auth repository. Real Supabase sign-in unverified |
| A2 | ☐ A `profiles` row with role `inspector` is created automatically on signup. | pgTAP: profile exists after `auth.users` insert |
| A3 | ◐ Sign-out clears the session; the protected screen unmounts and sign-in returns. | Widget test ✅ run `606017a` proves the routing; real session teardown unverified |
| A4 | ☑ An unauthenticated client is refused by every application table (raises `42501`; stricter than returning zero rows). | CI run `d53d066` ✅ |
| A5 | ☑ A user cannot escalate their own role to `admin`, but can still rename themselves. | CI run `d53d066` ✅ |

## B. Inspection CRUD

| # | Criterion | Evidence |
|---|---|---|
| B1 | ◐ An inspector creates an inspection with site name, address, client, and date. | Widget test vs. a **fake** repository — true end-to-end needs a live Supabase project |
| B2 | ☑ Required-field and length constraints reject invalid input at the database, not only in the UI. | CI run `d53d066` ✅ |
| B3 | ☐ An inspector can edit and delete their own inspection. | Flutter test |
| B4 | ☑ Deleting an inspection cascades to its items and photo rows. | CI run `d53d066` ✅ |
| B5 | ☑ A submitted inspection cannot be returned to draft (D10), and `submitted_at` is stamped automatically. | CI run `d53d066` ✅ |

## C. Punch-list items

| # | Criterion | Evidence |
|---|---|---|
| C1 | ☐ Items can be added, edited, and deleted within an inspection. | Flutter test |
| C2 | ☐ Items can be reordered, and the order survives a reload. | Flutter test asserting `position` round-trip |
| C3 | ☑ Severity and status are constrained to their enums. | CI run `d53d066` ✅ |

## D. Photos

| # | Criterion | Evidence |
|---|---|---|
| D1 | ☐ One or more photos attach to an item and upload to the private bucket. | Flutter integration test |
| D2 | ☐ Objects are stored at `{inspector_id}/{inspection_id}/{item_id}/{photo_id}.{ext}`. | Storage path assertion |
| D3 | ☐ Photos render from short-lived signed URLs, never a public URL. | Code review + no public bucket in migrations |
| D4 | ☐ Uploads outside the caller's own prefix are rejected. | pgTAP storage-policy test |
| D5 | ☐ Oversized (>10 MB) or non-image uploads are rejected. | pgTAP CHECK test |

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
| G1 | ☐ A PDF generates on-device with no network connection. | Flutter test, offline |
| G2 | ☐ It contains site info, inspector name, inspection date, and every item with description, area, severity, and status. | Golden test over extracted text |
| G3 | ☐ Item photographs are embedded. | Assertion on embedded image count |
| G4 | ☐ Multi-page pagination is correct for a 25-item inspection. | Golden/page-count test |
| G5 | ☐ Output is credible enough to show a client. | Committed sample PDF in `docs/evidence/` |

## H. History and search

| # | Criterion | Evidence |
|---|---|---|
| H1 | ◐ An inspector sees only their own inspections, newest first. | Ordering: widget test. Isolation: pgTAP `020` ✅ |
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

## K. Tests

| # | Criterion | Evidence |
|---|---|---|
| K1 | ☑ `flutter analyze --fatal-infos` reports zero issues. | CI run `606017a` ✅ |
| K2 | ☑ Flutter unit + widget tests pass — **28 tests**, 0 failures. | CI run `606017a` ✅ |
| K6 | ☑ `dart format --set-exit-if-changed` is clean. | CI run `606017a` ✅ |
| K3 | ☑ pgTAP suite passes against a clean migration run. | CI run `d53d066` ✅ |
| K4 | ☐ Admin lint, typecheck, and tests pass. | CI log |
| K5 | ☑ Tests are deterministic — no ordering dependence, no wall-clock flake. | CI run `d53d066` ✅ |

## L. Builds and release evidence

| # | Criterion | Evidence |
|---|---|---|
| L1 | ◐ Android APK builds in CI and is uploaded as an artifact. | **Blocked**: the self-hosted runner has no Android SDK (`No Android SDK found`) |
| L2 | ☑ iOS build verification runs on a macOS runner (no signing required). | CI run `33351235214` ✅ 1m52s — at `c796b6f`; not re-run since (macOS runners billing-blocked) |
| L3 | ☐ The admin production build succeeds. | CI log |
| L4 | ☑ Migrations apply cleanly from empty to head. | CI run `d53d066` ✅ |
| L5 | ☐ CI is green on the default branch. | Actions run URL |

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

## CI verification status — run `33355639632` at `2decd50` (self-hosted T410s)

| Gate | Result |
|---|---|
| Detect slices | ✅ 17s |
| Secret hygiene | ✅ 17s |
| `dart format --set-exit-if-changed` | ✅ |
| `flutter analyze --fatal-infos` | ✅ zero issues |
| `flutter test` | ✅ **28 passed, 0 failed** |
| Generate Android scaffolding | ✅ |
| **Database + RLS** | ✅ **1m44s** |
| Build release APK | ❌ `No Android SDK found` — runner not provisioned |
| iOS build verification | ❌ job refused — GitHub billing (only `macos-latest` job) |

Both remaining failures are **environmental, not code**. No gate was weakened or
skipped, and both still fail loudly.

The database gate now passes on the service box. Its earlier failure was
`db-verify.sh`'s own disk fail-fast — the guard working as designed, not a
regression — and was resolved by giving Docker a dedicated 126 GB partition
reclaimed from two unused NTFS partitions, rather than by lowering the floor.
