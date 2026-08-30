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
| A1 | ☐ A new user can sign up and sign in with email + password. | Flutter integration test |
| A2 | ☐ A `profiles` row with role `inspector` is created automatically on signup. | pgTAP: profile exists after `auth.users` insert |
| A3 | ☐ Sign-out clears the local session; protected screens are unreachable afterwards. | Flutter widget test |
| A4 | ◐ An unauthenticated client is refused by every application table (raises `42501`; stricter than returning zero rows). | pgTAP `040` — written, awaiting CI |
| A5 | ◐ A user cannot escalate their own role to `admin`, but can still rename themselves. | pgTAP `040` — written, awaiting CI |

## B. Inspection CRUD

| # | Criterion | Evidence |
|---|---|---|
| B1 | ☐ An inspector creates an inspection with site name, address, client, and date. | Flutter test + row in DB |
| B2 | ☐ Required-field and length constraints reject invalid input at the database, not only in the UI. | pgTAP CHECK-constraint tests |
| B3 | ☐ An inspector can edit and delete their own inspection. | Flutter test |
| B4 | ◐ Deleting an inspection cascades to its items and photo rows. | pgTAP `050` — written, awaiting CI |
| B5 | ◐ A submitted inspection cannot be returned to draft (D10), and `submitted_at` is stamped automatically. | pgTAP `050` — written, awaiting CI |

## C. Punch-list items

| # | Criterion | Evidence |
|---|---|---|
| C1 | ☐ Items can be added, edited, and deleted within an inspection. | Flutter test |
| C2 | ☐ Items can be reordered, and the order survives a reload. | Flutter test asserting `position` round-trip |
| C3 | ☐ Severity and status are constrained to their enums. | pgTAP |

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
| F2 | ◐ Sync is idempotent — running it twice produces no duplicate rows. | pgTAP `050` (DB level) — written, awaiting CI; Flutter level pending |
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
| H1 | ☐ An inspector sees only their own inspections, newest first. | Flutter test + pgTAP isolation test |
| H2 | ☐ Search matches on site name, address, and client. | Test over the GIN index |
| H3 | ☐ Search returns no other inspector's rows. | pgTAP |

## I. Admin dashboard

| # | Criterion | Evidence |
|---|---|---|
| I1 | ☐ An admin signs in and lists all **submitted** inspections. | Admin test |
| I2 | ☐ An admin opens a submitted inspection and sees its items and photos. | Admin test |
| I3 | ☐ A non-admin signing into the dashboard sees no inspections but their own. | Admin test |
| I6 | ◐ An admin cannot read a `draft` inspection, its items, its photos, or its storage objects — including by direct id. | pgTAP `030` — written, awaiting CI |
| I7 | ◐ An admin cannot read the profile of an inspector who has only drafts. | pgTAP `030` — written, awaiting CI |
| I4 | ◐ Every admin write attempt is rejected by the database, including creating an inspection of their own. | pgTAP `030` — written, awaiting CI |
| I5 | ☐ The service-role key appears in no client bundle. | Grep over `.next` build output — asserted in CI |

## J. Security / RLS

| # | Criterion | Evidence |
|---|---|---|
| J1 | ◐ RLS is enabled **and forced** on all four application tables. | pgTAP `010` — written, awaiting CI |
| J2 | ◐ Every cell of the `DATA_MODEL.md` §5 matrix has a passing test. | pgTAP suite; mapping in `DATA_MODEL.md` §9 |
| J3 | ◐ Inspector A cannot read or mutate inspector B's data at any level of the chain — both the raising and the silent-denial shapes. | pgTAP `020` — written, awaiting CI |
| J4 | ◐ No policy grants unrestricted `authenticated` CRUD (no bare `true` qualifier). | pgTAP `010` — written, awaiting CI |
| J5 | ☐ No secret is committed. | CI secret scan |

## K. Tests

| # | Criterion | Evidence |
|---|---|---|
| K1 | ☐ `flutter analyze` reports zero issues. | CI log |
| K2 | ☐ Flutter unit + widget tests pass. | CI log |
| K3 | ☐ pgTAP suite passes against a clean migration run. | CI log |
| K4 | ☐ Admin lint, typecheck, and tests pass. | CI log |
| K5 | ☐ Tests are deterministic — no ordering dependence, no wall-clock flake. | Suite passes 3× consecutively in CI |

## L. Builds and release evidence

| # | Criterion | Evidence |
|---|---|---|
| L1 | ☐ Android APK builds in CI and is uploaded as an artifact. | Actions artifact |
| L2 | ☐ iOS build verification runs on a macOS runner (no signing required). | CI log — *feasibility caveat below* |
| L3 | ☐ The admin production build succeeds. | CI log |
| L4 | ☐ Migrations apply cleanly from empty to head. | CI log |
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
