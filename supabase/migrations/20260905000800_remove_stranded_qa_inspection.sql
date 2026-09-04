-- Removes one stranded inspection left behind by real-device QA on 2026-09-01.
--
-- `Device QA Persistence 123726` is a fixture from a persistence check on real hardware,
-- not demo content. It is visible to the published demo admin account and appears in the
-- review console beside the three inspections the demo walkthrough describes, which makes
-- docs/DEMO.md wrong when it tells a visitor there are three.
--
-- It cannot be removed by the account that made it. D17 restricts DELETE on inspections to
-- draft rows, the row is submitted, and there is no unsubmit. The smoke cleanup job cannot
-- reach it either: that job deletes only ids named in the manifest of the run that created
-- them, and this row came from device QA rather than from a smoke run. So it needs a
-- migration, which is also the only route the deploy channel permits for a prod data
-- change.
--
-- Deleted by explicit id, never by name or pattern — the same rule hosted-smoke.yml states
-- for its own cleanup. The name, inspector and submission timestamp are repeated in the
-- WHERE clause as a guard, not as a filter: if that id ever refers to a different row than
-- the one surveyed here, every predicate fails together and nothing is deleted.
--
-- Idempotent: re-running deletes nothing once the row is gone.
--
-- Cascade, verified against 20260831000100_schema.sql rather than assumed:
--   inspection_items.inspection_id           -> inspections (id)                on delete cascade
--   item_photos     (item_id, inspection_id) -> inspection_items (id, inspection_id) on delete cascade
-- The one child item (3f0be5a6-f31a-4309-857c-ae815895f5fc, 'Persistence check item') goes
-- with it. The row carries no photos, so there is nothing orphaned in the storage bucket
-- and no storage.objects cleanup is needed. That was checked, not presumed: a delete here
-- could not have removed a storage object anyway, and leaving a file behind would be worse
-- than leaving the row.
--
-- RLS is FORCE-enabled on inspections, so the delete relies on the migration role holding
-- BYPASSRLS. If it does not, this fails loudly rather than silently deleting nothing.

delete from public.inspections
 where id           = '41c43817-5907-4b4a-b39f-26c6c7d32964'
   and site_name    = 'Device QA Persistence 123726'
   and inspector_id = 'd71ee5ce-4668-4354-aadc-e0ec8f4b4b81'
   and status       = 'submitted'
   and submitted_at = timestamptz '2026-09-01 13:13:58.436248+00';
