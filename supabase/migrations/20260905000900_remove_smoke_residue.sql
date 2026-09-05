-- Removes four submitted inspections the hosted smoke test left behind on 2026-09-05.
--
-- Every hosted smoke run submits one fixture named `SMOKE run<id>x<attempt> submitted
-- do-not-keep` and relies on the cleanup job to delete it under the service-role key.
-- On the ci.yml path that job never received the key — a called workflow's `secrets`
-- context holds only what the caller passes, and the key is deliberately on no caller's
-- list — so the rows from runs 33933212105, 33935381654, 33936856376 and 33938892430
-- stayed, visible to the published demo admin beside the three inspections DEMO.md
-- describes. docs/DEPLOY.md §5 records the diagnosis; .github/workflows/smoke-cleanup.yml
-- is the fix for future runs. This migration is the floor being mopped after the leak
-- is stopped.
--
-- They cannot be removed any other way. D17 restricts DELETE on inspections to draft rows
-- and all four are submitted; the manifests the cleanup job would have named them by
-- expired after a day; and the deploy channel permits prod data changes only through
-- migrations. Same route, same rules as 20260905000800.
--
-- Deleted by explicit id, never by name or pattern. Name, inspector, status and
-- submission timestamp are repeated per row as a guard, not a filter: if an id ever
-- refers to a different row than the one surveyed, every predicate fails together and
-- that row stays. Idempotent.
--
-- Cascade, verified against 20260831000100_schema.sql: each row carries exactly one
-- inspection_items child and zero item_photos (surveyed 2026-09-05 02:50Z), so nothing
-- is orphaned in the storage bucket and no storage.objects cleanup is needed.
--
-- RLS is FORCE-enabled on inspections; the delete relies on the migration role holding
-- BYPASSRLS and fails loudly otherwise.

delete from public.inspections
 where inspector_id = 'd71ee5ce-4668-4354-aadc-e0ec8f4b4b81'
   and status       = 'submitted'
   and (id, site_name, submitted_at) in (
     ('5113fcd3-a71e-4a8f-aadb-2dd098833425', 'SMOKE run33933212105x1 submitted do-not-keep', timestamptz '2026-09-05 01:00:04.642153+00'),
     ('72a60c84-5a48-413e-9ed6-8dde79999dcf', 'SMOKE run33935381654x1 submitted do-not-keep', timestamptz '2026-09-05 01:35:01.467587+00'),
     ('4a3a40f3-ebe2-448c-b695-d931d704b6cc', 'SMOKE run33936856376x1 submitted do-not-keep', timestamptz '2026-09-05 01:44:26.526757+00'),
     ('0b3867cf-655a-46d3-975f-fe176d4e8b1a', 'SMOKE run33938892430x1 submitted do-not-keep', timestamptz '2026-09-05 02:49:39.429998+00')
   );
