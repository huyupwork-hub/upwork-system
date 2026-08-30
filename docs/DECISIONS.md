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
