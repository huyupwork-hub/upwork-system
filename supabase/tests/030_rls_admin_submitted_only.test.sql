-- D3: the admin is a READ-ONLY overlay, scoped to status = 'submitted'.
-- Draft inspections stay private to their owning inspector, including from admins.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

set local request.jwt.claims = '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local role authenticated;

select ok(public.is_admin(), 'the admin fixture resolves as admin');

-- ---------------------------------------------------------------- read scope

select is((select count(*)::int from public.inspections), 1,
  'admin sees exactly the one submitted inspection');

select is((select id from public.inspections),
  'a0000000-0000-4000-8000-000000000002'::uuid,
  'admin sees the submitted inspection specifically');

select is((select count(*)::int from public.inspections where status = 'draft'), 0,
  'admin sees no draft inspection');

-- The draft is invisible even when named directly — not merely absent from a list view.
select is((select count(*)::int from public.inspections
           where id = 'a0000000-0000-4000-8000-000000000001'), 0,
  'admin cannot read inspector A''s draft by id');
select is((select count(*)::int from public.inspections
           where id = 'b0000000-0000-4000-8000-000000000001'), 0,
  'admin cannot read inspector B''s draft by id');

-- Children follow the parent's submitted status.
select is((select count(*)::int from public.inspection_items), 2,
  'admin sees only the two items under the submitted inspection');
select is((select count(*)::int from public.item_photos), 1,
  'admin sees only the one photo under the submitted inspection');
select is((select count(*)::int from public.inspection_items
           where inspection_id = 'a0000000-0000-4000-8000-000000000001'), 0,
  'admin cannot read items belonging to a draft');
select is((select count(*)::int from public.item_photos
           where inspection_id = 'b0000000-0000-4000-8000-000000000001'), 0,
  'admin cannot read photos belonging to a draft');

-- profiles is not a user directory: only inspectors with submitted work are visible.
select is((select count(*)::int from public.profiles
           where id = '11111111-1111-4111-8111-111111111111'), 1,
  'admin can read the profile of an inspector who has submitted work');
select is((select count(*)::int from public.profiles
           where id = '22222222-2222-4222-8222-222222222222'), 0,
  'admin cannot read the profile of an inspector with only drafts');

-- ---------------------------------------------------------------- I4: no writes

select throws_ok(
  $$insert into public.inspections (inspector_id, site_name, inspection_date)
    values ('33333333-3333-4333-8333-333333333333', 'Admin Site', date '2026-08-25')$$,
  '42501', null,
  'admin cannot insert an inspection'
);
select throws_ok(
  $$insert into public.inspection_items (inspection_id, title)
    values ('a0000000-0000-4000-8000-000000000002', 'Admin item')$$,
  '42501', null,
  'admin cannot insert an item into a submitted inspection they can read'
);

-- Writes that fail USING are silent, so assert the data afterwards.
select lives_ok(
  $$update public.inspections set site_name = 'ADMIN EDIT'
    where id = 'a0000000-0000-4000-8000-000000000002'$$,
  'admin update does not error'
);
select lives_ok(
  $$delete from public.inspections where id = 'a0000000-0000-4000-8000-000000000002'$$,
  'admin delete does not error'
);
select lives_ok(
  $$update public.inspection_items set severity = 'low'
    where inspection_id = 'a0000000-0000-4000-8000-000000000002'$$,
  'admin item update does not error'
);

-- Photo metadata. An admin reads these rows to review a submitted inspection, so
-- "read-only" has to mean they cannot add a photo to the record they are
-- reviewing, or remove one that is inconvenient. INSERT raises; DELETE is denied
-- by USING and so is silent, and is asserted against the data below.
select throws_ok(
  $$insert into public.item_photos
      (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('a1000000-0000-4000-8000-000000000002',
            'a0000000-0000-4000-8000-000000000002',
            '33333333-3333-4333-8333-333333333333/a0000000-0000-4000-8000-000000000002/x/y.jpg',
            'image/jpeg', 1024)$$,
  '42501', null,
  'admin cannot add photo metadata to a submitted inspection'
);
select lives_ok(
  $$delete from public.item_photos
    where id = 'a2000000-0000-4000-8000-000000000002'$$,
  'admin photo delete does not error'
);
select lives_ok(
  $$update public.item_photos set caption = 'ADMIN EDIT'
    where id = 'a2000000-0000-4000-8000-000000000002'$$,
  'admin photo update does not error'
);

reset role;

select is((select site_name from public.inspections where id = 'a0000000-0000-4000-8000-000000000002'),
  'Northgate Retail Park', 'admin UPDATE changed nothing');
select is((select count(*)::int from public.inspections where id = 'a0000000-0000-4000-8000-000000000002'),
  1, 'admin DELETE removed nothing');
select is((select count(*)::int from public.inspection_items
           where inspection_id = 'a0000000-0000-4000-8000-000000000002' and severity = 'low'),
  0, 'admin item UPDATE changed nothing');
select is((select count(*)::int from public.item_photos
           where id = 'a2000000-0000-4000-8000-000000000002'),
  1, 'admin photo DELETE removed nothing');
select is((select caption from public.item_photos
           where id = 'a2000000-0000-4000-8000-000000000002'),
  'Junction box, cover removed', 'admin photo UPDATE changed nothing');

select * from finish();
rollback;
