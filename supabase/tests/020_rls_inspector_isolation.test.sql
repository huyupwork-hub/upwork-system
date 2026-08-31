-- J3: inspector A cannot reach inspector B's data at any level of the chain.
--
-- Two distinct denial shapes are asserted, because RLS expresses them differently:
--   * INSERT violating WITH CHECK  -> raises 42501
--   * UPDATE/DELETE failing USING  -> affects zero rows, silently
-- A test that only checked for exceptions would miss the second and pass a broken policy.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------- as inspector A
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select is((select count(*)::int from public.inspections), 2,
  'inspector A sees exactly their own two inspections');

select is((select count(*)::int from public.inspections
           where inspector_id <> '11111111-1111-4111-8111-111111111111'), 0,
  'inspector A sees no row owned by another inspector');

select is((select count(*)::int from public.inspection_items), 3,
  'inspector A sees only items under their own inspections');

select is((select count(*)::int from public.item_photos), 2,
  'inspector A sees only photos under their own inspections');

-- A cannot create a row owned by B (WITH CHECK)
select throws_ok(
  $$insert into public.inspections (inspector_id, site_name, inspection_date)
    values ('22222222-2222-4222-8222-222222222222', 'Planted Site', date '2026-08-25')$$,
  '42501',
  null,
  'inspector A cannot insert an inspection owned by inspector B'
);

-- A cannot hand their own row to B (WITH CHECK on UPDATE)
select throws_ok(
  $$update public.inspections set inspector_id = '22222222-2222-4222-8222-222222222222'
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  '42501',
  null,
  'inspector A cannot reassign their own inspection to another inspector'
);

-- A cannot attach an item to B's inspection
select throws_ok(
  $$insert into public.inspection_items (inspection_id, title)
    values ('b0000000-0000-4000-8000-000000000001', 'Planted item')$$,
  '42501',
  null,
  'inspector A cannot add an item to inspector B''s inspection'
);

-- Silent-denial shape: these do not raise, they must simply match nothing.
select lives_ok(
  $$update public.inspections set site_name = 'HIJACKED'
    where id = 'b0000000-0000-4000-8000-000000000001'$$,
  'updating another inspector''s inspection does not error'
);
select lives_ok(
  $$delete from public.inspections where id = 'b0000000-0000-4000-8000-000000000001'$$,
  'deleting another inspector''s inspection does not error'
);
select lives_ok(
  $$update public.inspection_items set title = 'HIJACKED'
    where id = 'b1000000-0000-4000-8000-000000000001'$$,
  'updating another inspector''s item does not error'
);
select lives_ok(
  $$delete from public.item_photos where id = 'b2000000-0000-4000-8000-000000000001'$$,
  'deleting another inspector''s photo does not error'
);

-- ...and confirm, unprivileged view removed, that nothing actually changed.
reset role;

select is((select site_name from public.inspections where id = 'b0000000-0000-4000-8000-000000000001'),
  'Riverside Depot', 'inspector B''s inspection was not modified');
select is((select count(*)::int from public.inspections where id = 'b0000000-0000-4000-8000-000000000001'),
  1, 'inspector B''s inspection was not deleted');
select is((select title from public.inspection_items where id = 'b1000000-0000-4000-8000-000000000001'),
  'Damaged loading bay seal', 'inspector B''s item was not modified');
select is((select count(*)::int from public.item_photos where id = 'b2000000-0000-4000-8000-000000000001'),
  1, 'inspector B''s photo was not deleted');

-- ---------------------------------------------------------------- as inspector B
set local request.jwt.claims = '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local role authenticated;

select is((select count(*)::int from public.inspections), 1,
  'inspector B sees exactly their own single inspection');
select is((select count(*)::int from public.item_photos), 1,
  'inspector B sees exactly their own single photo');

-- Named directly rather than inferred from the count above. Inspector A's
-- SUBMITTED inspection is the row an admin is allowed to read; an ordinary
-- inspector must not inherit that visibility just because the admin console
-- exists. Submitting is what makes work reviewable, not public.
select is(
  (select count(*)::int from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000002'),
  0,
  'inspector B cannot read inspector A''s submitted inspection'
);
select is(
  (select count(*)::int from public.inspection_items
   where inspection_id = 'a0000000-0000-4000-8000-000000000002'),
  0,
  'nor its items'
);
select is(
  (select count(*)::int from public.item_photos
   where inspection_id = 'a0000000-0000-4000-8000-000000000002'),
  0,
  'nor its photo metadata'
);
select is(
  (select count(*)::int from public.profiles
   where id = '11111111-1111-4111-8111-111111111111'),
  0,
  'nor the submitting inspector''s profile'
);

-- H1/H3: search is scoped by the same policies
select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'Northgate')),
  0,
  'search does not leak another inspector''s inspection'
);

-- B can operate normally on their own data (policies are not merely restrictive)
select lives_ok(
  $$insert into public.inspections (inspector_id, site_name, inspection_date)
    values ('22222222-2222-4222-8222-222222222222', 'Second Site', date '2026-08-26')$$,
  'inspector B can create their own inspection'
);
select is((select count(*)::int from public.inspections), 2,
  'inspector B now sees two of their own inspections');

select * from finish();
rollback;
