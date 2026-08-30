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

## 6. Storage organisation

```
inspection-photos/
  {inspector_id}/{inspection_id}/{item_id}/{photo_id}.{ext}
```

The first path segment is the owner's `auth.uid()`, which makes the ownership rule a prefix
comparison with no join:

```sql
(storage.foldername(name))[1] = (SELECT auth.uid())::text
```

Ownership is therefore expressed identically in the database and in storage — the same
model, not two models that must be kept in agreement.

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

## 9. Verification

Every cell of the matrices above is asserted by pgTAP in `supabase/tests/`, run in CI (D1):

| File | Covers |
|---|---|
| `010_schema_posture.test.sql` | tables, RLS enabled + forced, no anon policy, no bare-`true` policy, no admin write policy, column privileges, private bucket |
| `020_rls_inspector_isolation.test.sql` | J3 cross-inspector isolation, both denial shapes |
| `030_rls_admin_submitted_only.test.sql` | D3 — admin reads submitted only, writes nothing |
| `040_privilege_escalation.test.sql` | A5/D4 self-escalation, A4 anon |
| `050_constraints_and_sync.test.sql` | constraints, D10 one-way submit, D5 idempotency, cascade |

Two denial shapes are asserted separately, because RLS expresses them differently: an
`INSERT` violating `WITH CHECK` raises `42501`, while an `UPDATE`/`DELETE` failing `USING`
affects zero rows *silently*. A suite that only checked for exceptions would pass a broken
policy, so every silent-denial case is followed by a privileged re-read confirming the data
did not change.
