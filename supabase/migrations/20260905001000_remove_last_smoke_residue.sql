-- Removes the one smoke fixture that predates the cleanup workflow.
--
-- `SMOKE run33940684616x2 submitted do-not-keep` was submitted by the re-run of PR #7's
-- own CI (attempt 2, 2026-09-05 04:10Z). That run's `hosted-smoke.yml` no longer carried
-- a purge job — PR #7 had just moved it into `.github/workflows/smoke-cleanup.yml` — and
-- `workflow_run` events only fire from the workflow file on the default branch, which did
-- not have it until the PR merged minutes later. So no cleanup ever named this row, and
-- its manifest artifact has since expired.
--
-- Everything after that merge cleans up after itself: run 33948142211 ended with
-- "nothing named remains". This is the last row of that kind, removed the same way as
-- 20260905000800 and 20260905000900: explicit id, guards repeated as predicates, no
-- pattern, idempotent. One child item, zero photos (surveyed 2026-09-05 05:56Z), so the
-- cascade reaches nothing in the storage bucket.
--
-- RLS is FORCE-enabled on inspections; the delete relies on the migration role holding
-- BYPASSRLS and fails loudly otherwise.

delete from public.inspections
 where id           = '62e48279-b482-471d-85fe-0315f602c530'
   and site_name    = 'SMOKE run33940684616x2 submitted do-not-keep'
   and inspector_id = 'd71ee5ce-4668-4354-aadc-e0ec8f4b4b81'
   and status       = 'submitted'
   and submitted_at = timestamptz '2026-09-05 04:10:30.83467+00';
