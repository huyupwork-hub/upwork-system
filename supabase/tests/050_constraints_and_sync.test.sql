-- Data integrity, the one-way submission rule (D10), and first-sync idempotency (D5).
-- These run as the owning inspector, so they exercise the real client path.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

-- ---------------------------------------------------------------- B2/C3 constraints

select throws_ok(
  $$insert into public.inspections (inspector_id, site_name, inspection_date)
    values ('11111111-1111-4111-8111-111111111111', '', date '2026-08-25')$$,
  '23514', null, 'an empty site_name is rejected by the database, not only the UI'
);

select throws_ok(
  $$insert into public.inspection_items (inspection_id, title, sort_order)
    values ('a0000000-0000-4000-8000-000000000001', 'Negative order', -1)$$,
  '23514', null, 'a negative sort_order is rejected'
);

select throws_ok(
  $$insert into public.item_photos (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('a1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
            'x/y/z/oversize.jpg', 'image/jpeg', 10485761)$$,
  '23514', null, 'D5: a photo larger than 10 MB is rejected'
);

select throws_ok(
  $$insert into public.item_photos (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('a1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
            'x/y/z/doc.pdf', 'application/pdf', 1000)$$,
  '23514', null, 'a non-image content_type is rejected'
);

-- D8: the composite FK makes a mismatched inspection_id impossible.
select throws_ok(
  $$insert into public.item_photos (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('a1000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
            'x/y/z/mismatch.jpg', 'image/jpeg', 1000)$$,
  '42501', null,
  'a photo cannot claim an inspection its parent item does not belong to'
);

-- Note the errcode above is 42501, not the composite FK''s 23503. Under D17 the
-- WITH CHECK is evaluated first, and the claimed inspection belongs to inspector
-- B, so RLS refuses before the foreign key is ever consulted. The mismatch is
-- still rejected; it is simply caught one layer earlier. The FK itself is proven
-- below, on two inspections the caller does own.

-- Submission is deliberately exercised at the END of this file. Under D17 a
-- submitted inspection is immutable, so submitting DRAFT_A early would deny
-- every constraint, cascade and idempotency assertion that follows it.

-- ---------------------------------------------------------------- D5: first sync

-- The device supplies the primary key, so a retried push is an upsert that cannot
-- duplicate. This is the whole of the conflict story for V1.
select lives_ok(
  $$insert into public.inspections (id, inspector_id, site_name, inspection_date)
    values ('c0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
            'Offline Draft Site', date '2026-08-27')
    on conflict (id) do nothing$$,
  'first push of a device-generated draft succeeds'
);

select lives_ok(
  $$insert into public.inspections (id, inspector_id, site_name, inspection_date)
    values ('c0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
            'Offline Draft Site', date '2026-08-27')
    on conflict (id) do nothing$$,
  'the same push replayed does not error'
);

select is(
  (select count(*)::int from public.inspections where id = 'c0000000-0000-4000-8000-000000000001'),
  1,
  'F2: replaying the first sync produces exactly one row, not two'
);

-- Item and photo pushes are idempotent on the same terms.
select lives_ok(
  $$insert into public.inspection_items (id, inspection_id, title)
    values ('c1000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'Offline item')
    on conflict (id) do nothing$$,
  'first push of a device-generated item succeeds'
);
select lives_ok(
  $$insert into public.inspection_items (id, inspection_id, title)
    values ('c1000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'Offline item')
    on conflict (id) do nothing$$,
  'replayed item push does not error'
);
select is(
  (select count(*)::int from public.inspection_items where inspection_id = 'c0000000-0000-4000-8000-000000000001'),
  1,
  'replayed item sync produces exactly one row'
);

-- storage_path is unique, so a replayed photo upload cannot create a second row.
select throws_ok(
  $$insert into public.item_photos (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('a1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
            '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000001/a1000000-0000-4000-8000-000000000001/a2000000-0000-4000-8000-000000000001.jpg',
            'image/jpeg', 482113)$$,
  '23505', null,
  'a duplicate storage_path is rejected'
);

-- ---------------------------------------------------------------- D8: composite FK
--
-- Both inspections here are owned by the caller and both are drafts, so RLS
-- permits the write and the composite foreign key is what rejects it. That is
-- the assertion D8 is actually about: a photo cannot name an inspection its
-- parent item does not belong to.

select throws_ok(
  $$insert into public.item_photos
      (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('a1000000-0000-4000-8000-000000000001',
            'c0000000-0000-4000-8000-000000000001',
            'x/y/z/owned-mismatch.jpg', 'image/jpeg', 1000)$$,
  '23503', null,
  'the composite FK rejects a photo whose item belongs to another inspection'
);

-- ---------------------------------------------------------------- B4: cascade
--
-- Uses the draft created above rather than DRAFT_A, so the cascade is proven on
-- a row that is unambiguously still mutable under D17.

select lives_ok(
  $$insert into public.item_photos
      (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('c1000000-0000-4000-8000-000000000001',
            'c0000000-0000-4000-8000-000000000001',
            '11111111-1111-4111-8111-111111111111/c0000000-0000-4000-8000-000000000001/c1000000-0000-4000-8000-000000000001/photo.jpg',
            'image/jpeg', 1024)$$,
  'a photo can be attached under a draft inspection'
);

select lives_ok(
  $$delete from public.inspections where id = 'c0000000-0000-4000-8000-000000000001'$$,
  'an inspector can delete their own draft inspection'
);

reset role;
select is((select count(*)::int from public.inspection_items
           where inspection_id = 'c0000000-0000-4000-8000-000000000001'), 0,
  'deleting an inspection cascades to its items');
select is((select count(*)::int from public.item_photos
           where inspection_id = 'c0000000-0000-4000-8000-000000000001'), 0,
  'deleting an inspection cascades to its photos');

-- ---------------------------------------------------------------- D10 + D17: submission

set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select lives_ok(
  $$update public.inspections set status = 'submitted'
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'an inspector can submit their own draft'
);

select isnt(
  (select submitted_at from public.inspections where id = 'a0000000-0000-4000-8000-000000000001'),
  null,
  'submitted_at is stamped automatically on submission'
);

-- Under D17 the update policy's USING clause no longer matches a submitted row,
-- so this is denied silently by matching nothing rather than raising from the
-- D10 trigger. The trigger remains as defence in depth; RLS simply refuses
-- first, so the assertion is about the data, not an exception.
select lives_ok(
  $$update public.inspections set status = 'draft', submitted_at = null
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'attempting to un-submit does not raise'
);

select is(
  (select status::text from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000001'),
  'submitted',
  'D10/D17: a submitted inspection cannot be returned to draft'
);

select * from finish();
rollback;
