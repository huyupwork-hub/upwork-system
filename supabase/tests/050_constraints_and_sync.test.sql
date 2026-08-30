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
    values ('a1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002',
            'x/y/z/mismatch.jpg', 'image/jpeg', 1000)$$,
  '23503', null, 'a photo cannot claim an inspection its parent item does not belong to'
);

-- ---------------------------------------------------------------- D10: one-way submit

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

select throws_ok(
  $$update public.inspections set status = 'draft', submitted_at = null
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  '23514', null,
  'D10: a submitted inspection cannot be returned to draft'
);

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

-- ---------------------------------------------------------------- B4: cascade

select lives_ok(
  $$delete from public.inspections where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'an inspector can delete their own inspection'
);

reset role;
select is((select count(*)::int from public.inspection_items
           where inspection_id = 'a0000000-0000-4000-8000-000000000001'), 0,
  'deleting an inspection cascades to its items');
select is((select count(*)::int from public.item_photos
           where inspection_id = 'a0000000-0000-4000-8000-000000000001'), 0,
  'deleting an inspection cascades to its photos');

select * from finish();
rollback;
