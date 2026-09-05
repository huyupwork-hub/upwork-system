# Database & Security Model

**Status: implemented.** Materialised in `supabase/migrations/`, asserted by the pgTAP
suite in `supabase/tests/`, and executed locally against PGlite (§9).

Derived from the workflows in `SPEC.md` and the access-control model, in that order.

## 1. Entities and relationships

```
auth.users (Supabase-managed)
   |  1:1
profiles ──────1:N──────> inspections ──────1:N──────> inspection_items
   (role)                  (owner)                          |  1:N
                                                       item_photos
```

- `profiles.id` **is** `auth.users.id` — no surrogate key, no drift.
- `inspections.inspector_id → profiles.id` — the single ownership anchor. Every policy in
  the system resolves ownership through this column.
- `inspection_items` and `item_photos` inherit ownership through their parent chain and
  cascade on delete.

## 2. Enums

| Type | Values |
|---|---|
| `app_role` | `inspector`, `admin` |
| `inspection_status` | `draft`, `submitted` |
| `item_severity` | `low`, `medium`, `high`, `critical` |
| `item_status` | `open`, `resolved` |

## 3. Tables

### `profiles`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | FK → `auth.users(id)` ON DELETE CASCADE |
| `role` | `app_role` | NOT NULL, DEFAULT `inspector`, **not client-writable** (D4) |
| `full_name` | `text` | NOT NULL, CHECK length 1–120 — printed on the PDF |
| `created_at` / `updated_at` | `timestamptz` | NOT NULL, DEFAULT `now()` |

Populated by an `AFTER INSERT ON auth.users` trigger, so a profile always exists.

### `inspections`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | **device-generated** — the idempotency key for first sync (D5) |
| `inspector_id` | `uuid` | NOT NULL, FK → `profiles(id)` ON DELETE CASCADE |
| `site_name` | `text` | NOT NULL, CHECK length 1–200 |
| `site_address` | `text` | nullable, CHECK ≤ 300 |
| `client_name` | `text` | nullable, CHECK ≤ 200 |
| `inspection_date` | `date` | NOT NULL |
| `status` | `inspection_status` | NOT NULL, DEFAULT `draft`; `submitted` is one-way (D10) |
| `submitted_at` | `timestamptz` | CHECK: non-null iff `status = 'submitted'`; stamped by trigger |
| `created_at` / `updated_at` | `timestamptz` | NOT NULL, DEFAULT `now()` |
| `search_tsv` | `tsvector` | **generated, stored** — see §6 |

### `inspection_items`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | device-generated |
| `inspection_id` | `uuid` | NOT NULL, FK → `inspections(id)` ON DELETE CASCADE |
| `sort_order` | `int` | NOT NULL, CHECK `>= 0` — non-unique (D7); named to avoid the `POSITION` keyword |
| `title` | `text` | NOT NULL, CHECK length 1–200 |
| `description` | `text` | nullable, CHECK ≤ 4000 |
| `area` | `text` | nullable, CHECK ≤ 120 — room/zone within the site |
| `severity` | `item_severity` | NOT NULL, DEFAULT `medium` |
| `status` | `item_status` | NOT NULL, DEFAULT `open` |
| `created_at` / `updated_at` | `timestamptz` | NOT NULL, DEFAULT `now()` |

Carries `UNIQUE (id, inspection_id)` — not redundant with the PK: it is the target of the
composite FK from `item_photos` (D8).

### `item_photos`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | device-generated |
| `item_id` | `uuid` | NOT NULL |
| `inspection_id` | `uuid` | NOT NULL — denormalised (D8) |
| `storage_path` | `text` | NOT NULL **UNIQUE** — a replayed upload cannot create a second row |
| `caption` | `text` | nullable, CHECK ≤ 500 |
| `content_type` | `text` | NOT NULL, CHECK in (`image/jpeg`, `image/png`, `image/webp`) |
| `byte_size` | `bigint` | NOT NULL, CHECK `> 0 AND <= 10485760` (10 MB) |
| `created_at` | `timestamptz` | NOT NULL, DEFAULT `now()` |

```sql
FOREIGN KEY (item_id, inspection_id)
  REFERENCES inspection_items (id, inspection_id) ON DELETE CASCADE
```

This is what makes the denormalisation safe — `inspection_id` cannot disagree with its
parent item's.

## 4. Ownership model

One rule, applied everywhere:

> A row is owned by the inspector identified by the `inspections.inspector_id` at the root
> of its parent chain. Ownership is never stored twice except where a composite FK proves
> the copy correct.

`auth.uid()` is compared against that anchor in every policy. Admin is a separate,
read-only overlay resolved by `public.is_admin()` (D9).

## 5. RLS matrix

RLS is `ENABLE`d **and** `FORCE`d on all four tables. No table has a policy for `anon`,
and `anon` holds no table privilege at all — anonymous requests are refused before RLS is
consulted, raising `42501` rather than returning an empty set.

Legend: ✅ allowed · ❌ denied

### `profiles`
| Operation | anon | self | other inspector | admin |
|---|---|---|---|---|
| SELECT | ❌ | ✅ own row | ❌ | ✅ only inspectors who have submitted work |
| INSERT | ❌ | ❌ (trigger only) | ❌ | ❌ |
| UPDATE | ❌ | ✅ own row — **only `full_name` is granted** (D4) | ❌ | ❌ |
| DELETE | ❌ | ❌ | ❌ | ❌ |

`profiles` is deliberately not a user directory: an admin cannot enumerate inspectors who
have only drafts.

### `inspections`
| Operation | anon | owner | other inspector | admin |
|---|---|---|---|---|
| SELECT | ❌ | ✅ | ❌ | ✅ **only `status = 'submitted'`** |
| INSERT | ❌ | ✅ `WITH CHECK (inspector_id = auth.uid() AND NOT is_admin())` | ❌ | ❌ |
| UPDATE | ❌ | ✅ USING + WITH CHECK both pinned to owner, plus `NOT is_admin()` | ❌ | ❌ |
| DELETE | ❌ | ✅ | ❌ | ❌ |

Two details that verification proved are load-bearing:

- The `WITH CHECK` on UPDATE matters as much as the `USING`. Without it an owner could
  reassign `inspector_id` and hand the row to another user.
- The `NOT is_admin()` conjunct is **not** redundant. Policies are role-agnostic and an
  admin is also an `authenticated` user, so ownership alone would still let an admin
  create inspections of their own — making D3's "read-only" false.

### `inspection_items` and `item_photos`
| Operation | anon | owner (via parent) | other inspector | admin |
|---|---|---|---|---|
| SELECT | ❌ | ✅ | ❌ | ✅ **only where the parent is `submitted`** |
| INSERT | ❌ | ✅ parent must be owned | ❌ | ❌ |
| UPDATE | ❌ | ✅ | ❌ | ❌ |
| DELETE | ❌ | ✅ | ❌ | ❌ |

Ownership predicate, e.g. for `inspection_items`:

```sql
EXISTS (
  SELECT 1 FROM public.inspections i
  WHERE i.id = inspection_items.inspection_id
    AND i.inspector_id = (SELECT auth.uid())
)
```

`(SELECT auth.uid())` is wrapped deliberately — it lets the planner evaluate the call once
per statement rather than once per row.

### Storage bucket `inspection-photos`
| Operation | anon | owner | other inspector | admin |
|---|---|---|---|---|
| SELECT (download) | ❌ | ✅ own prefix | ❌ | ✅ **only under a `submitted` inspection** |
| INSERT (upload) | ❌ | ✅ own prefix | ❌ | ❌ |
| UPDATE | ❌ | ✅ own prefix | ❌ | ❌ |
| DELETE | ❌ | ✅ own prefix | ❌ | ❌ |

Bucket is **private**; clients render images through short-lived signed URLs. Segment `[2]`
of the object name is the inspection id, compared **as text** against a subquery of
`id::text` — casting an untrusted path segment to `uuid` would raise inside the policy on a
malformed name instead of simply denying. Comparing text fails closed.

### Storage bucket `inspection-reports`
| Operation | anon | owner | other inspector | admin |
|---|---|---|---|---|
| SELECT (download) | ❌ | ✅ own prefix | ❌ | ✅ **only the pinned name under a `submitted` inspection** |
| INSERT (upload) | ❌ | ✅ **exactly `{uid}/{inspection_id}/report.pdf`, only while `submitted`, once** | ❌ | ❌ |
| UPDATE | ❌ | ❌ | ❌ | ❌ |
| DELETE | ❌ | ❌ | ❌ | ❌ |

Private, PDF-only (by header), 50 MB. No UPDATE or DELETE policy exists for this bucket for
any role: write-once by absence. The INSERT policy pins the whole object name, so the unique
`(bucket_id, name)` makes a second upload a `23505` (SQL) or a `Duplicate` (Storage API)
rather than a second object (D21 amended, D31).

Who can do what to a stored report, actor by actor — every line is a `110` or hosted-smoke
22a–22e assertion:

- **anon** — no policy of any kind; an upload raises `42501`, and there is nothing to list or
  sign.
- **owner, inspection still `draft`** — the name is not in the submitted set, so an upload
  is `42501` (D21's eligibility rule, enforced at the server as well as in the loader). The
  own prefix lists and signs, and holds nothing a client could have written.
- **owner, inspection `submitted`** — one upload, at exactly `{uid}/{id}/report.pdf`; a
  second is `23505` from SQL or `Duplicate` from the Storage API. No UPDATE policy, so the
  API's `x-upsert` path is refused; no DELETE policy, so `remove()` matches zero rows and
  returns `[]`. Lists and signs the own prefix.
- **other inspector** — `42501` on any upload, whether the owner segment is forged or the
  inspection id is somebody else's; lists nothing under another prefix; signs nothing.
- **admin** — `42501` on upload: an admin owns no submitted inspection, and `080` asserts no
  admin write policy exists on storage. Lists and signs only the pinned name under submitted
  inspections; an object planted beside it, or under a draft, is invisible by construction.
- **inspector promoted to admin** — may publish the report of their *own* earlier submitted
  inspection and nothing else; reads own plus submitted. Recorded in D31 rather than
  excluded, for the `080` reason.
- **service role / dashboard** — anything, deliberately: the only cleanup path
  (`smoke_purge.dart --report`).
- **the Storage API itself** — checks for an existing object and then writes the final
  `storage.objects` row as a privileged user, so two devices racing on one pinned name can
  both land bytes; same owner, content-equivalent renderings, still one object. "Exactly one
  object, never replaced by a client" is what is claimed — not "exactly one upload ever
  landed".

MIME is pinned at the bucket (`allowed_mime_types`) by the `Content-Type` header, not by
sniffing bytes; size is capped at 50 MB at the bucket and mirrored in
`ReportLimits.maxBytes`, which `constraint_parity_test.dart` reads from the migration. A
`storage.objects` row without bytes behind it — a phantom that signs but does not download
— could be inserted through PostgREST only if the project exposed the `storage` schema;
`DEPLOY.md` §3 records that read-back.

## 6. Storage organisation

```
inspection-photos/
  {inspector_id}/{inspection_id}/{item_id}/{photo_id}.{ext}
inspection-reports/
  {inspector_id}/{inspection_id}/report.pdf
```

The first path segment is the owner's `auth.uid()`, which makes the ownership rule a prefix
comparison with no join:

```sql
(storage.foldername(name))[1] = (SELECT auth.uid())::text
```

Ownership is therefore expressed identically in the database and in storage — the same
model, not two models that must be kept in agreement.

The report's name is fixed by its INSERT policy rather than chosen by the client, so one
object per inspection is a uniqueness fact — `storage.objects (bucket_id, name)` — not a
convention the client is trusted to keep (D31). The same literal is spelled in three
places and pinned on each: the migration (pgTAP `110`), `reportStoragePath` in
`apps/mobile` (`report_store_test.dart`) and `reportStoragePath` in `apps/admin`
(`repository.test.ts`); hosted smoke 22a proves they meet.

Which reports exist is read from a listing of `{inspector_id}/`, never from a flag (D27),
and a listing is only ever read whole: the Storage API returns 100 entries unless asked
for more and says nothing about the rest, so an id left off a truncated page would read as
"not uploaded" — a claim (D28). The phone pages the folder to a short page
(`SupabaseReportStore.listPageSize`, 1000); the console asks for 1000 and prints a dash
for every row of an inspector whose listing filled that page (`REPORT_FOLDER_LIST_LIMIT`).

## 7. Indexes

| Index | Purpose |
|---|---|
| `inspections (inspector_id, created_at DESC)` | history list, the default screen query |
| `inspections (inspector_id) WHERE status = 'draft'` — partial | draft/sync lookups |
| `inspections (submitted_at DESC) WHERE status = 'submitted'` — partial | admin review queue |
| `inspections USING GIN (search_tsv)` | full-text search (W8) |
| `inspection_items (inspection_id, sort_order)` | ordered item fetch (D7) |
| `item_photos (item_id)` | photos for an item |
| `item_photos (inspection_id)` | RLS predicate + whole-report photo fetch for the PDF |

Search vector:

```sql
search_tsv tsvector GENERATED ALWAYS AS (
  to_tsvector('simple'::regconfig,
    coalesce(site_name, '') || ' ' ||
    coalesce(site_address, '') || ' ' ||
    coalesce(client_name, ''))
) STORED
```

`'simple'` rather than `'english'`: site names, addresses and company names are proper
nouns, where stemming hurts more than it helps. The `::regconfig` cast is required — without
it the expression is not immutable and cannot back a generated column.

## 8. Migrations

| File | Contents |
|---|---|
| `20260831000100_schema.sql` | enums, four tables, constraints, seven indexes |
| `20260831000200_functions.sql` | `is_admin`, `handle_new_user`, `set_updated_at`, `enforce_submission_transition`, five triggers |
| `20260831000300_rls.sql` | enable + force RLS, grants, 18 policies |
| `20260831000400_storage.sql` | private bucket, five storage policies |
| `20260831000500_submitted_immutable.sql` | D17: every write policy on the three child tables and the photo bucket requires the governing inspection to be `draft` |
| `20260905000600_function_hardening.sql` | withdraw the default EXECUTE on the trigger functions from client roles, pin `search_path` |
| `20260905000700_signup_gate.sql` | `signup_allowlist`; `handle_new_user` refuses any address not on it |
| `20260905000800_remove_stranded_qa_inspection.sql` | delete one device-QA row by id |
| `20260905000900_remove_smoke_residue.sql` | delete four smoke-residue rows by id |
| `20260905001000_remove_last_smoke_residue.sql` | delete the one smoke row that predates the cleanup workflow, by id |
| `20260905001100_inspection_reports.sql` | private report bucket, three storage policies |

## 9. Verification

Every cell of the matrices above is asserted by pgTAP in `supabase/tests/`, run in CI (D1):

| File | Covers |
|---|---|
| `010_schema_posture.test.sql` | tables, RLS enabled + forced, no anon policy, no bare-`true` policy, no admin write policy, column privileges, private bucket |
| `020_rls_inspector_isolation.test.sql` | J3 cross-inspector isolation, both denial shapes |
| `030_rls_admin_submitted_only.test.sql` | D3 — admin reads submitted only, writes nothing |
| `040_privilege_escalation.test.sql` | A5/D4 self-escalation, A4 anon |
| `050_constraints_and_sync.test.sql` | constraints, D10 one-way submit, D5 idempotency, cascade |
| `060_rls_items_crud.test.sql` | punch-item CRUD through the parent inspection, owner and non-owner, resolve/reopen in both directions |
| `070_submitted_immutable.test.sql` | D17 — a submitted inspection, its items and its photos are frozen; drafts unaffected and still submittable |
| `080_storage_photo_ownership.test.sql` | storage object ownership by path segment, private bucket, draft-only writes, no admin write policy on storage |
| `090_search_ownership.test.sql` | search is an ordinary SELECT under RLS, both directions; the order is total |
| `095_function_hardening.test.sql` | no EXECUTE for client roles, pinned `search_path`, the triggers still fire |
| `100_signup_gate.test.sql` | a stranger cannot provision an account; the allowlist is unreadable and unwritable by any client role |
| `110_inspection_reports.test.sql` | D21 amended / D31 — one write-once report per submitted inspection; owner, non-owner, admin and anon denials; no update/delete policy; unique index posture |

Two denial shapes are asserted separately, because RLS expresses them differently: an
`INSERT` violating `WITH CHECK` raises `42501`, while an `UPDATE`/`DELETE` failing `USING`
affects zero rows *silently*. A suite that only checked for exceptions would pass a broken
policy, so every silent-denial case is followed by a privileged re-read confirming the data
did not change. A third shape arrived with `110`: a second `INSERT` at a name the unique
`(bucket_id, name)` index already holds raises `23505`. The order matters when reading that
file — Postgres evaluates the RLS `WITH CHECK` before the heap insert and the unique index
after it, so the owner's duplicate passes the policy and then hits the index, while an actor
the policy refuses gets `42501` even at a name already taken.
