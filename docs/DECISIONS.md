# Decisions

Only decisions that would otherwise become ambiguous later. Short by design.

Status: **Accepted** = agreed with the project owner. **Proposed** = needs sign-off before
the dependent slice is implemented.

---

### D1 — CI is the primary verification vehicle — *Accepted*
Flutter, Docker, the Supabase CLI and `psql` are not installed on the development machine.
GitHub Actions runs `flutter analyze/test/build`, the containerised Supabase stack for
database and RLS tests, and the admin lint/typecheck/test/build.
**Why:** evidence must survive verification, and CI logs plus build artifacts are stronger
portfolio evidence than local runs.
**Consequence:** a GitHub remote is required before any acceptance criterion can be
claimed. Local development is limited to editing and Node-based checks.

### D2 — Hosted Supabase project — *Accepted*
The project targets a hosted Supabase project. The `anon` key is the only key that reaches
Flutter or the browser. The `service_role` key lives solely in GitHub Actions secrets and
the owner's local environment; it is never committed and never shipped to a client.

### D3 — Administrators are read-only, and see submitted work only — *Accepted*
Admin policies grant `SELECT` only, and only where `status = 'submitted'`. Draft
inspections — and their items, photos and storage objects — stay private to the owning
inspector, including from admins. `profiles` is likewise not a user directory: an admin
sees only the profiles of inspectors who have submitted work.
**Why:** smallest defensible policy surface, and unfinished field work is not review
material.
**Enforcement detail found during verification:** the ownership policies are role-agnostic,
and an admin is also an `authenticated` user — so ownership alone would still have let an
admin create inspections of their own. The write policies on `inspections` therefore carry
an explicit `and not public.is_admin()`. Without it, "read-only" was false.
**Extension path:** a narrow `review_status` / `reviewer_notes` column with a
column-scoped admin `UPDATE` policy, if review actions are wanted later.

### D4 — `profiles.role` is not client-writable — *Accepted*
`GRANT SELECT ON public.profiles` plus `GRANT UPDATE (full_name)` — a column-scoped
**grant**. A user may rename themselves but cannot escalate to `admin`.
**Why the mechanism matters:** the first implementation used a table-wide `GRANT UPDATE`
followed by `REVOKE UPDATE (role)`. That does nothing. PostgreSQL stores table-level and
column-level privileges separately, so the table-wide grant still covers every column and
the revoke never takes effect. Verification caught this; granting only the writable
columns is the form that actually holds.

### D5 — Offline scope is new drafts only — *Accepted*
Offline support covers creating and editing an inspection that is still in `draft` status
and has never been pushed. Once synced, editing requires connectivity.
**Conflict semantics:** a draft exists in exactly one place until its first push, so there
is no concurrent-writer case to resolve. Push is an idempotent upsert keyed on the
device-generated UUID primary key; a retried sync cannot duplicate rows.
**Why:** satisfies "keep drafting without connectivity" and "local changes are not
silently lost" without building a general synchronisation framework, tombstones, or an
operation outbox.
**Accepted limitation:** an inspection created online cannot be edited offline.
Deliberate scope control for the two-day build target. No tombstones, no operation
outbox, no conflict-resolution machinery unless a later requirement explicitly needs one.

### D6 — PDF is generated client-side in Flutter — *Accepted*
On-device rendering via the `pdf` package.
**Why:** the offline requirement is primary — an inspector must be able to produce a
report in the field. Also avoids a server round-trip and any service-role exposure.
**Consequence:** the admin dashboard cannot regenerate a byte-identical PDF without
duplicating layout logic. Server-side rendering is recorded as a V1 non-goal.

### D7 — Item ordering uses a non-unique `sort_order` column — *Accepted*
`inspection_items.sort_order` is a plain integer with a non-unique composite index on
`(inspection_id, position)`; ties break on `created_at`.
**Why:** a unique constraint makes reordering require multi-statement shuffles or deferred
constraints for no product benefit at this scale. Named `sort_order` rather than
`position` because `POSITION` is a SQL keyword.

### D8 — `item_photos` carries a denormalised `inspection_id` — *Accepted*
Integrity is enforced by a composite foreign key to `inspection_items (id, inspection_id)`,
so the denormalised value cannot drift from its parent.
**Why:** lets photo RLS policies reach the owning inspection in one join instead of two,
and keeps a single source of truth despite the denormalisation.

### D9 — Role lookups use a `SECURITY DEFINER` helper — *Accepted*
`public.is_admin()` is `SECURITY DEFINER`, `STABLE`, with `search_path = ''`.
**Why:** a policy on `profiles` that itself queries `profiles` recurses; a definer function
breaks the cycle.
**Alternative considered:** a JWT custom claim via an auth hook — fewer per-row reads, but
adds an auth hook and makes role changes lag until token refresh. Revisit if policy
performance becomes a measured problem, not before.

### D10 — Submission is one-way — *Accepted, flagged for review*
A trigger rejects any `submitted → draft` transition, and stamps `submitted_at` on
submission so the column cannot disagree with `status`.
**Why:** D3 gates admin visibility on `status = 'submitted'`. If an inspector could return
a submitted inspection to draft, they could retract it from review at will and the review
gate would be unenforceable. Fails closed.
**Flagged:** this was not explicitly specified. It is the only reading consistent with D3,
but if inspectors should be able to recall a submission, drop the
`inspections_enforce_submission` trigger — one line, no schema change.
**Not decided:** a submitted inspection currently remains editable by its owner. Locking
content on submission would be a larger change and is not required by the stated workflow.

### D11 — Realtime is disabled in config; the service box verifies the database only — *Accepted*
`supabase/config.toml` sets `[realtime] enabled = false`. Local verification runs
`./scripts/db-verify.sh`, which brings up Postgres alone (`supabase db start`) and runs the
migration and pgTAP gates against it.
**Why the flag and not `supabase start -x realtime`:** the CLI runs the Realtime image as a
one-shot seeding job from inside *database* startup, not as part of the service phase.
`internal/db/start.initSchema15` appends `initRealtimeJob` whenever `Config.Realtime.Enabled`
is set, and does so before the project's own migrations are applied. The `-x` list only
filters the long-running containers, so `-x realtime` never reaches that job — excluding the
service does not skip the seeder. On the T410s service box the seeder aborts with SIGILL
(exit 132) inside the Realtime image's Erlang runtime, which is consistent with the image
being built for a newer x86-64 baseline than that CPU provides. The flag is the only
supported switch that removes the job.
**Consequence for CI:** `supabase start` no longer boots the Realtime container. Nothing in
the suite ever asserted against Realtime, so no coverage is lost, and CI gains a step that
fails the build if the flag is flipped back — otherwise the service box breaks silently.
**Local-only limitation:** the service box exercises the database gate only — migrations,
Postgres, pgTAP, RLS. The `auth` and `storage` *schemas* are present, because the CLI applies
them as migration jobs during database startup rather than from the running services, so the
policies in `20260831000400_storage.sql` are testable. GoTrue, Storage, PostgREST, Kong,
Studio and Edge Runtime are not running, so nothing requiring an HTTP endpoint — real JWT
issuance, signed URLs, the Data API — can be exercised there. Those stay CI-only. D1 is
unchanged: CI remains authoritative.
**Reversal:** if Realtime ever enters scope, set the flag to `true` and drop the CI guard.
The service box would then need different hardware, not a different config.

### D12 — Flutter platform scaffolding is generated in CI, not committed — *Accepted*
`apps/mobile` commits Dart source only: `pubspec.yaml`, `analysis_options.yaml`, `lib/`,
`test/`. The `android/` and `ios/` directories are produced by
`flutter create --platforms=… .` as a CI step before the build.
**Why:** no Flutter toolchain exists on the development machine (D1), so `flutter create`
could not be run to produce them. Hand-writing the Android scaffolding would mean
committing a binary `gradle-wrapper.jar` written blind — worse than regenerating a
template the Flutter tool owns anyway.
**Consequence:** the CI step restores `lib/ test/ pubspec.yaml analysis_options.yaml` from
git immediately after `flutter create`, because the template rewrites files it considers
its own. It also injects `android.permission.INTERNET` into the *main* manifest: the
Flutter template grants it only in the debug and profile manifests, so a release APK would
otherwise ship with no network and every Supabase call would fail.
**Reversal:** once Flutter is installed locally, run `flutter create --platforms=android,ios .`
once, commit the result, and delete the two CI scaffolding steps. Nothing else changes.

### D13 — V1 has sign-in only, no in-app sign-up — *Accepted*
The app authenticates existing users. Accounts are created in the Supabase dashboard or by
seed.
**Why:** the Definition of Done begins at `login`, not `register`. Adding a sign-up form
means email confirmation, password policy and a full-name capture step — none of which the
stated V1 workflow requires.
**Profile bootstrap:** no client-side creation path exists or is needed. The
`on_auth_user_created` trigger creates the `profiles` row, and the app *reads* it after
sign-in. If it is missing, `ProfileMissingException` surfaces to the user rather than the
app inventing a profile — a missing row means the schema bootstrap failed and must be
visible, not patched over at runtime.

### D14 — The Figma Make file is visual direction; the schema is the contract — *Accepted*
Where the mockup (`figma.com/make/JPL6m3DdiYxMRljlM67SiD`) and the accepted
SPEC/DATA_MODEL/RLS model disagree, **the schema and product decisions win**. The Figma
supplies palette, metrics, and interaction patterns only.

Conflicts found on first read, and how each was settled:

| Mockup | Accepted model | Resolution |
|---|---|---|
| Editable `Inspector` field | `inspector_id` from session; RLS `WITH CHECK` | **Read-only display.** An editable field would promise assignment the database refuses |
| `Template` picker | not in schema | Dropped; not in V1 |
| No Client field | `client_name`, indexed in `search_tsv` | Client field **added** to the form |
| 5 statuses incl. `syncing`, `offline` | `draft`, `submitted` | Two persisted states. Connectivity is transient UI state, never stored — conflating them would undermine D5 |
| Severity `minor/major/critical` | `low/medium/high/critical` | Schema wins; revisit only via an explicit migration |
| Punch status `in-review` | `open`, `resolved` | Schema wins |
| `org`, `license`, `assignee`, `city`, `notes` | absent | Not added — organisation/multi-tenancy is an explicit V1 exclusion |
| Face ID, password reset | not in SPEC | Not implemented; both are product features, not visual direction |
| `Reports` / `Settings` tabs | not in V1 workflow | Absent. PDF is a later slice; Settings is unscoped |
| Home search + status segmented control | SPEC W8 | Deferred to the search slice, not this one |

**Adopted from the mockup:** `#007AFF` / `#F2F2F7` / `rgba(60,60,67,·)` system palette,
14pt card radius with a 0.5pt hairline border, 44pt rows (50pt on sign-in), right-aligned
form values, uppercase 13/600 section headers, the shield mark (drawn as a `CustomPainter`
from the source vector rather than adding an SVG dependency), the white sign-in ground with
"Field inspection, simplified.", and New Inspection as a bottom sheet with a grab handle.
