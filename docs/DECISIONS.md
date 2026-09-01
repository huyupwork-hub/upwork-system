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
**Implemented in D24–D27.** Those record what the build actually does, including the
one place D5 turned out not to be true yet: the client was not sending the
device-generated key at all.

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
**Ordering must be stated explicitly in the client, and was not.** `postgrest-dart`'s
`order()` takes `ascending = false` as its **default**, so `.order('sort_order')` reads
the punch list *descending*. Every server-side read of `inspection_items` and
`item_photos` had this from the beginning. It was not only a display fault:
`SupabaseInspectionItemsRepository.create` derives the next position from
`existing.last.sortOrder + 1`, so under a descending read `last` was the *smallest*
value and the third item onwards collided with the second.
**Why it survived so long:** the in-memory fake sorts ascending, so no host-side test
could see it, and no test had ever asserted the order of *two* items read back from the
real database — the hosted smoke attached one item and one photo. Hosted smoke case 32,
written for the offline slice, is the first to read two synced items back, and it failed
on the first run. `ascending: true` is now written out at every call site.

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
**Superseded in part by D17:** the question of whether a submitted inspection stays
editable was left open here and is now closed — it does not. See D17 for the enforcement
and D18 for how post-submit changes will eventually be made.

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

### D15 — iOS is a separate, manual-only workflow — *Accepted*
The main CI workflow (`.github/workflows/ci.yml`) contains only jobs that can run
to completion on the self-hosted Linux runner: detect, secret hygiene, database + RLS,
Flutter format/analyze/test, Android build, and later the admin checks. iOS lives in
`.github/workflows/ios.yml` with a `workflow_dispatch` trigger and no automatic one.
**Why:** iOS needs a macOS runner. GitHub-hosted macOS minutes are billing-blocked on
this account and the only self-hosted runner is Linux, so the job was refused within
2–3 seconds of every single run. A permanently red job that says nothing about the code
trains people to ignore red, and devalues the gates that do mean something.
**What this is not:** iOS is not emulated on Linux, not skipped-as-success, and not
marked passed. `ACCEPTANCE.md` L2 records it as pending, macOS-only, with the one
genuine execution it has had (run `33351235214`, 1m52s, at `c796b6f`) and the fact that
it is unverified at HEAD.
**Reversal:** restore hosted macOS minutes — fix billing or make the repository public —
or register a self-hosted macOS runner, then either dispatch `ios.yml` or fold the job
back into `ci.yml`. Note that making the repository public while a self-hosted runner is
attached would let fork pull requests execute code on that machine; move `runs-on` back
to GitHub-hosted in the same change.

### D16 — CI caches live on the runner's disk, not in `actions/cache` — *Accepted*
No `actions/cache` steps. `~/.gradle` (→ `/data/gradle`), `~/.pub-cache`, `~/android-sdk`
and `actions-runner/_work/_tool` (→ `/data/runner-work`) persist between runs;
`actions/checkout` cleans only the workspace, never `$HOME`.
**Why:** on a self-hosted runner `actions/cache` would upload and re-download gigabytes
over the network to replace a cache already sitting on local disk — slower than the thing
it optimises, and it consumes repository cache quota.
**Consequence:** the first cold Gradle build took 1263s; warm builds reuse `~/.gradle`.
Nothing in CI may clear these paths, and jobs stay serial — one runner, 5.6 GB of RAM, so
parallelism would trade a working build for an out-of-memory one.
**Storage layout this depends on:** the 126 GB volume is mounted at `/data`, with
`/data/docker` bind-mounted to `/var/lib/docker`. `/data` must remain traversable
(`0755`); it was `0710` at first because Docker hardens its own data root, which is what
broke the Gradle lock file.

### D17 — A submitted inspection is immutable — *Accepted*
Once `inspections.status = 'submitted'`, the owning inspector can no longer edit or
delete the inspection, its items, or its photos. Reads are unaffected; admin behaviour
(D3) is unchanged; there is no unsubmit.
**Enforced in the database**, in `20260831000500_submitted_immutable.sql`, not in Flutter:
every write policy on `inspections`, `inspection_items`, `item_photos` and the storage
bucket now requires the governing inspection to be `draft`. A UI-only lock would leave the
write path open to any client holding a valid JWT.
**Why this supersedes D10's open question:** D10 recorded that a submitted inspection
remained editable and that locking it had been considered but not adopted. That left a real
integrity hole — what an admin reviewed could change underneath them, silently.
**The mechanism that makes submission still possible:** an UPDATE policy's `USING` clause is
evaluated against the OLD row and `WITH CHECK` against the NEW one. `using (status =
'draft')` therefore still permits the draft → submitted transition itself, while refusing
every subsequent update. `WITH CHECK` must *not* require draft, or submitting would deny
itself. This is the subtle part, and `070_submitted_immutable.test.sql` asserts both halves.
**Consequence for D10's trigger:** `enforce_submission_transition` now rarely fires, because
RLS refuses first — a denied update matches zero rows rather than raising. The trigger stays
as defence in depth and to stamp `submitted_at`. Test `050` was rewritten accordingly: it
now asserts the un-submit is denied *silently* and verifies the data, rather than expecting
the trigger's exception.

### D18 — Post-submit changes will create a new revision, not mutate the submitted one — *Accepted (deferred)*
The intended future mechanism is `submitted revision → Create Revision → new draft
revision`. The earlier submitted revision stays immutable and permanently represents what
was issued at that time.
**Not implemented in V1.** Doing it correctly means cloning items and photos, revision
numbering, history, PDF revision selection, and the integrity rules binding those together
— a slice of its own, not a corner of this one.
**V1 behaviour is therefore:** draft editable, submitted read-only, no unsubmit, no direct
mutation after submit, and no Create Revision action.
**Compatibility check performed, so revisioning is not accidentally foreclosed:** the only
unique constraints in the schema are `inspection_items (id, inspection_id)` — per-row — and
`item_photos.storage_path`, which is global but embeds the inspection, item and photo ids.
A cloned revision receives fresh UUIDs and therefore fresh paths, so revisions of the same
site cannot collide. Nothing keys on `(site_name, inspection_date)` or similar, so two
revisions of one site coexist without conflict. Adding revisions later means new columns
(a revision number and a link to the previous revision) plus clone logic — additive, with
no rewrite of what exists.
**Deliberately not done now:** no `revision_number`, no `parent_inspection_id`, no
`revision_group_id`. Adding them speculatively would ship columns nothing reads, which is
the kind of half-migration that constrains the real design later.

### D19 — Photo write ordering, and what happens when half of it fails — *Accepted*
Two stores, two orders, no distributed transaction.

**Upload:** object first, then the metadata row. If the metadata insert fails, the
just-uploaded object is deleted (compensation). The reverse order would briefly expose a
row pointing at nothing, which renders as a broken image.

**Delete:** metadata row first, then the object. If the object delete fails, the row stays
deleted and `PhotoCleanupException` is thrown so the failure is visible.
**Why that order:** an orphaned object is invisible to every query and reclaimable; an
orphaned metadata row is a broken image in the UI. Recreating the row after a failed object
delete would resurrect a photo the user asked to remove, so it is not attempted.
**Why no cleanup queue:** the path is deterministic —
`{inspector}/{inspection}/{item}/{photo}.{ext}` — and is recomputable from the metadata, so
a reclaim pass can be written later without any bookkeeping added now. A queue would be a
subsystem to maintain in exchange for tidying something nothing can see.
**Testability is why the ports exist:** `PhotoObjectStore` and `PhotoMetadataStore` are two
narrow interfaces so `photo_workflow_test.dart` can force "the metadata insert failed" and
observe the compensation. A test that cannot force that proves nothing about the ordering.
They are not an abstraction layer: one production implementation each, one fake each.

### D20 — `image_picker`, behind a `PhotoSource` seam — *Accepted*
Camera and gallery only, via `image_picker`. `ImagePickerPhotoSource` is the single file
that imports it; everything above talks to the `PhotoSource` interface.
**Why the seam:** a platform channel cannot run in `flutter test`, so without it the whole
attach flow would be untestable on the host. With it, the widget tests drive a fake and the
plugin boundary stays one file.
**Capture evidence:** real camera capture is Android device/build evidence, not something a
host-side test can prove. CI proves the app builds and that the attach flow works against a
fake source; the hosted smoke proves the upload path against real Storage.
**Content type comes from the bytes**, sniffed by magic number, not from the filename or
the platform's claim — the same reason the storage path never trusts a caller. `image_picker`
re-encodes when `imageQuality` is set, so its reported mime type is advisory at best.
**The "compression pipeline" is a size cap and nothing more:** `maxWidth/maxHeight` 2048 and
`imageQuality` 85, so a 12 MP phone photo does not arrive at 8 MB and get rejected after the
user has waited for it.

### D21 — The PDF is a projection, not a stored artefact — *Accepted*
`DB state → ReportSnapshot → PDF bytes`. Nothing about a report is persisted: no
report table, no generated-PDF upload, no editable report content. Regenerating always
reproduces the current submitted record.
**Why no upload to Storage:** a stored PDF becomes a second source of truth the moment the
underlying record changes, and under D17 the record cannot change — so the stored copy
would add a staleness risk in exchange for nothing. If a concrete requirement for retained
copies appears (an audit trail, an emailed artefact), that is its own slice.
**Snapshot, loaded once:** the loader reads the inspection, profile, items, photo metadata
and photo bytes in one pass, then the renderer works purely from that. Nothing queries
Supabase while pages are laid out — otherwise a change or a dropped connection mid-render
could produce a document whose header and body disagree.
**Eligibility:** submitted only. A draft is still changing, so a document made from it
would claim a permanence it does not have. Generation never submits as a side effect —
asking to see a report must not be the act that makes an inspection permanent. The check
lives in the loader, and the UI simply has no report action on a draft: an affordance that
can never succeed is worse than its absence.
**An unfetchable photo aborts generation.** `ReportPhotoUnavailableException` names the
object and the report is not produced. A placeholder was built first and rejected: a
document that renders "unavailable" where evidence should be still looks complete to
whoever receives it, and an inspection report is exactly the artefact where a silent gap
matters. Failing is louder and recoverable — retry once the connection is back.
**Cost accepted:** one transient fetch failure blocks the whole report rather than
degrading it. That is the intended trade for a document that is either complete or absent.
**Ports:** `ReportRenderer` and `ReportSharer`. The renderer is pure — snapshot in, bytes
out — so `report_renderer_test.dart` asserts on real PDF output; the sharer keeps
`printing`'s platform channel out of every widget test.
**Deliberately absent:** charts, AI summary, signatures, template engine, server-side
generation, email, PDF history/versioning, revision selection.

### D22 — Search is server-side over the existing tsvector; ordering is a total order — *Accepted*
`searchMine(query)` matches in Postgres against the stored `search_tsv` generated column
and its GIN index, both of which already existed (DATA_MODEL §7). **No migration was
needed and no index was added.**
**Not client-side filtering:** fetching every row and filtering in Dart would neither scale
nor respect what the policies are for. Because search is an ordinary `SELECT`, RLS applies
to it exactly as to the history list — a query cannot become a way to discover rows the
caller could not already read. pgTAP `090` asserts that in both directions, and the hosted
smoke proves it against the real client with per-run unique tokens.
**Prefix, not infix:** each term is sent as `term:*`, so "north" finds "Northgate". Infix
matching ("gate" → "Northgate") would need `pg_trgm` and a second index; it is not what
this search is for. The `'simple'` config lowercases what it indexes, so case-insensitivity
costs nothing.
**Input is reduced to letters and digits.** `&`, `|`, `!`, `:`, `(`, `)` and quotes are
tsquery syntax; passing them through would either error or let a caller compose an
expression of their own. A query with nothing searchable in it returns null and the caller
shows the full history rather than an empty result the user cannot explain.
**Ordering is `inspection_date DESC, created_at DESC, id DESC`** for both history and
search — one `_query` method builds both, so they cannot drift. The final key is what makes
the order *total*: two inspections on the same date written in one transaction would
otherwise come back in either order between calls, which is exactly the H1 gap this closes.
**Staleness is handled with a generation counter, not a framework.** Each load takes the
next token and applies its result only if still newest, so a slow response for "a" cannot
land after a fast one for "abc". Rows stay on screen while a newer request is in flight —
blanking them would make every keystroke flash the list away. No debounce: the token makes
out-of-order responses harmless, and a timer would add latency and another moving part.

### D23 — The admin console adds no privilege — *Accepted*
The Next.js review console is a second **client** of the same database, not a second
authority over it. It signs in with ordinary email/password, holds only the publishable
key, and every query runs as the reviewer's own `authenticated` session — so the admin
`SELECT` policies (D3) decide what comes back, exactly as they did before the console
existed. There is no privileged client anywhere in `apps/admin`.
**No migration was needed.** The policies written for D3 already satisfy the accepted admin
contract: `inspections_select_admin_submitted`, `inspection_items_select_admin_submitted`,
`item_photos_select_admin_submitted`, `profiles_select_admin` and the storage read policy
grant `SELECT` only and only where the owning inspection is `submitted`; there is no admin
write policy of any kind, and the ownership write policies carry `and not public.is_admin()`.
Two *assertions* were missing rather than two policies, and were added: an admin attempting
to add or remove photo **metadata**, and an ordinary inspector attempting to read another
inspector's **submitted** row — the case that only becomes interesting once a review console
exists, since submitting is what makes work reviewable, not public.
**The role gate is not a substitute for RLS.** `resolveAccess` refuses a non-admin before
any page renders, and fails closed when the profile cannot be read. Without it an inspector
reaching `/inspections` would get a working console listing their *own* submitted work —
not a leak, but not a review console either. Both layers stay: remove the gate and nothing
leaks; remove RLS and everything does.
**Read-only is asserted, not intended.** The repository interface has no write method, and a
test renders the detail view and fails if it contains a `button`, `form`, `input`, `select`
or `textarea`. A control that the database would refuse is still a lie told to the reviewer.
**Search is the same search.** The console mirrors the Flutter client's tsquery construction
against the one stored `search_tsv` and its existing GIN index — no second index, no second
semantics. `test/search.test.ts` pins the cases the Dart tests pin, because two clients
querying one column must not disagree about what a word matches.
**No second PDF engine** (D21). The console presents submitted data in a report-oriented
view; the Flutter client remains the only thing that generates a document, and nothing is
persisted.

### D24 — Offline lives at the repository boundary, as two decorators — *Accepted*
`OfflineFirstInspectionsRepository` and `OfflineFirstInspectionItemsRepository`
implement the interfaces the app already talks to and delegate to the Supabase ones
whenever the server is reachable. No widget asks whether it is online.
**Why that seam:** the alternative is connectivity checks sprinkled through the New
Inspection sheet, the punch-list editor and History — three places that would then
have to be kept in agreement, and a second draft editor to maintain. Here there is one
create path, one item editor and one history, and the offline behaviour is a property
of the data layer.
**What they are not:** a cache. Nothing server-backed is stored locally — no submitted
inspections, no other people's work, no read-through mirror. The queue holds drafts
that originated on this device and have never been pushed, and that is all it will ever
hold. A server-backed record while offline is simply unavailable, and the banner says
so rather than the list quietly looking complete.
**The Figma's `syncing`/`offline` statuses stay unstored** (D14). Being unsynced is
rendered as a second pill beside `Draft`, from the queue's contents, never from a
column. After a sync one of those two facts is still true and the other is not, which
is exactly why they are not one field.
**A network call the seam did not own defeated all of it, and real-device QA found it.**
`InspectionsScreen` loaded the inspector's `profiles` row before the history, and that
call goes straight to PostgREST. With a warm in-memory profile — which is the state
after signing in online — nothing showed. On a cold start with no connection it threw,
the whole screen rendered a raw DNS error, and **no inspections appeared at all**: the
draft was safely in `shared_preferences` and completely unreachable, which to an
inspector is indistinguishable from having lost it. The `+` action was gated on the same
profile, so creating a draft offline was dead too — the one thing this slice exists for.
**The rule this establishes:** the offline boundary is only as good as the *slowest*
thing the screen waits for. The history now loads first and the profile is optional; a
missing name hides the footer and omits the sheet's Inspector row rather than blocking
anything, because ownership was never decided by what that row printed (D14).
**Why 263 passing tests missed it:** `FakeProfileRepository` had no way to be
unreachable. The inspections fake had been given one; the profile fake had not, so every
"offline" test ran half-connected. Any fake standing in for something across a network
needs an unreachable mode, or it quietly proves less than it appears to.

### D25 — A refusal is not an outage — *Accepted*
`isTransportFailure` classifies every failure before anything is queued. A
`PostgrestException`, `StorageException` or `AuthException` means the server answered,
and the error is re-thrown to the caller. Only a genuine transport failure —
`SocketException`, `HttpException`, `HandshakeException`, `TimeoutException`,
`AuthRetryableFetchException`, `http`'s `ClientException` — puts a draft on the device.
**Why this is load-bearing:** treating every failure as "offline" would stash drafts
the database has already rejected — a constraint violation, or an RLS denial — and they
would sit in the queue failing forever while the UI implied they were waiting for
signal. The user would be told their work was safe when it was unacceptable.
**Connectivity is a trigger, never authority.** No connectivity package is used and no
correctness depends on one: an interface that is up says nothing about whether Supabase
answers, and a captive portal is a full-strength connection to nothing. The push itself
is what determines reachability. Retry is triggered on app open and on resume, plus a
Retry control in the banner that reaches the same code path deterministically. No
polling, no background service, no scheduler.

### D26 — The device generates the key, and sync is a verified merge-upsert — *Accepted*
Ids for inspections and items are minted on the device before any write is attempted,
and a push is `ON CONFLICT (id) DO UPDATE` through PostgREST's default upsert.
**A gap D5 had left open:** `inspections.id` was documented in the migration as "the
idempotency key for first sync", but the Flutter client never sent it — every insert let
`gen_random_uuid()` apply, so a retried write was indistinguishable from a new one. The
client now sends it on every create, online and offline alike. That also closes the
uglier case: an insert that reaches Postgres whose response is lost is stashed locally
under the key the server already holds, so the sync that follows lands on that row
instead of creating a second one.
**Merge rather than ignore-duplicates.** A draft whose first push failed part-way stays
editable on the device, so a retry must carry whatever changed since. `DO NOTHING` would
push the row once and silently ignore every later edit, and the app would report a sync
that had not delivered the current work. Items merge on the same terms, including
`status` — which an ordinary insert omits so the column default applies, but a re-push
must send, or an item resolved in the field syncs back as `open`.
**No migration was needed.** The existing policies already permit exactly this and
nothing more: the INSERT `WITH CHECK` governs the proposed row, the UPDATE `USING`
governs the existing one, and D17's `status = 'draft'` conjunct means a submitted row
refuses the merge outright. pgTAP `050` now asserts the merge path in both directions —
an owner may overwrite their own draft, a merge cannot reassign `inspector_id`, and a
merge cannot land on another inspector's row.
**Success is read back, never inferred.** RLS refuses UPDATE and DELETE by matching zero
rows *silently*, so the absence of an exception proves nothing. Sync re-reads the
inspection and the item ids and compares them against what it holds; only then is the
local record removed. Items the inspector deleted after a partial push are pruned, so
"synced" describes a server record that matches the device.

### D27 — The handoff is a deletion, and Submit stays a server transition — *Accepted*
A local draft has no `synced` state. Once the push is verified the record is **removed**
from the queue, and Supabase/RLS is the authority from that moment.
**Why a deletion rather than a flag:** a `synced` marker on the device would be a second
writable authority for a row the server already owns, which is the dual-source-of-truth
bug this design exists to avoid. Absence cannot disagree with the database. It also
makes the merge in History trivially correct — a row that exists in both places under
one key appears once, with the server's copy winning.
**Offline Submit is refused at the repository, not merely hidden.** `submit` raises
`DraftNotSyncedException` for anything still in the queue, and the detail screen shows
an explanation where the button would be — absent, not disabled, the same rule the add
and report affordances already follow. A locally applied "submitted" would be a claim no
server ever made: `submitted_at` is stamped by a trigger (D10) and immutability is a
database rule (D17), and there would be nothing to unwind once it turned out false.
**`shared_preferences` for the queue**, behind a `DraftStore` port. It is already in the
graph — `supabase_flutter` persists the auth session with it — so this declares an
existing plugin rather than adding native code. sqflite or drift would add a schema,
migrations and a code generator to serialise a handful of unsynced drafts read only as a
whole, and would invite the local mirror of Supabase that D24 refuses.
**Unreadable stored bytes are an error, never an empty queue.** The first implementation
of the decoder absorbed a parse failure and returned `[]`, on the reasoning that a broken
app is worse than a lost queue. That was wrong, and it contradicted E3 in this slice's own
acceptance list: an empty queue reads as "you have no offline drafts", the app carries on,
and the next ordinary save writes a fresh document straight over bytes that still held the
inspector's only copy of their work. Silent data loss, caused by the recovery.
`DraftStoreUnreadableException` is raised instead; the raw value is left untouched, the
failure is remembered so no later caller sees an empty list, and **every write is refused**
while it stands. The decoder catches only `FormatException`, `TypeError` and
`ArgumentError` — the three ways *persisted data* can be wrong — so a `StateError` or a
`NoSuchMethodError` still propagates as the bug it is rather than being reported to the
user as damaged storage.
**No recovery UI, and deliberately no reset.** Clearing the store is the destructive
action, so nothing in the data layer is entitled to take it; if a reset is ever offered it
is a user's explicit choice, made with the bytes still present. What exists now is the
honest minimum: preserve, refuse, explain.
**Offline photos are not in this slice.** ACCEPTANCE E1 mentions them; they are recorded
as E1b and deferred, because they need a durable local file store (a new `path_provider`
dependency), deterministic photo ids so a retry cannot duplicate a Storage object, and
local-file rendering in the photo strip — a slice of its own rather than a corner of this
one. E1a, the draft and its punch items, is what closes here.
