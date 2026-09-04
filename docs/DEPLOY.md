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
| Android build | https://github.com/huyupwork-hub/upwork-system/releases/tag/v0.1.0-demo |
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
| `20260905000600_function_hardening` | withdraw default EXECUTE, pin `search_path` | **NO — unverified** |
| `20260905000700_signup_gate` | close self-signup at the database | **NO — unverified** |
| `20260905000800_remove_stranded_qa_inspection` | delete one QA row | **NO — unverified** |

The last three are committed on `slice/security-migration` and have **never executed**.
They are not applied and must not be applied until CI has run them. See §6.

### Self-signup is currently OPEN

As of 2026-09-05, `GET /auth/v1/settings` on this project returns `"disable_signup": false`,
and `profiles.role` defaults to `inspector`. A stranger can create an account and write
their own inspections, items and photos under the inspector policies.

`20260905000700_signup_gate` closes this at the database. The matching project-level
setting is not in this repository and has to be turned off separately:

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

```bash
vercel deploy --prod --scope thun-viet
```

**Auto-deploy is off.** The Vercel account is not linked to the GitHub identity that
authors the commits, so git-triggered builds are blocked and production is deployed by
hand. The consequence is in §6.

### Android APK

CI already builds a commit-tagged release APK, so a release should take that artifact
rather than a local build:

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

**None to cite.** This is a gap, not an omission.

The repository has **zero self-hosted runners registered**:

```
GET repos/huyupwork-hub/upwork-system/actions/runners
{"total_count":0,"runners":[]}
```

Every job in `ci.yml` declares `runs-on: [self-hosted, Linux, X64]`, so run
`33920282984` on PR #6 is queued and cannot start. Until a runner returns, no CI run URL
can be quoted for the three pending migrations, and no commit-tagged APK artifact exists
to attach to a release.

---

## 6. What is mocked, limited, or unverified

**The deployed commit is unknown.** Because production is deployed by hand, the live
deployment `dpl_7mY5ksjdvqk8jC9NqZtRWuQpKPRh` (created 2026-09-02) carries no commit, no
branch and no SHA. `DEMO.md` previously named `f12d71d`; that could not be reproduced from
the deployment, and its timestamp points at a different commit again. Until production is
redeployed from a known commit and that commit is written down, "the APK matches the
deployed commit" cannot be stated truthfully by anyone.

**Reports are generated on the device, and nothing is stored.** PDF rendering is Flutter-only
(D6), the PDF is a projection rather than an artefact (D21), and the console deliberately
contains no second PDF engine (D23). The console says so on screen. There is no cloud PDF,
and the demo admin cannot download one.

**Offline photo capture does not work.** Drafts and punch items work offline; attaching a
photo does not. Deferred with its reasoning in `DECISIONS.md` D27.

**Cold start when opened offline takes around 30 seconds.** The history waits for a profile
lookup to fail before rendering. Latency, not a correctness problem.

**iOS is unverified.** It needs a macOS runner, which this project has never had.

**Seed data does not yet meet the demo it describes.** Of the submitted inspections visible
to the demo admin, only two carry photographs. One row, `Device QA Persistence 123726`, is
a fixture stranded by real-device QA rather than demo content;
`20260905000800_remove_stranded_qa_inspection` removes it, and until that migration is
applied `DEMO.md` overstates the demo by describing three inspections where four are
visible.

**Storage is private.** Photographs are served through short-lived signed URLs; the bucket
has no public path.
