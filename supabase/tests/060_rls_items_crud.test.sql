-- Punch-item CRUD isolation.
--
-- `020` proves an inspector cannot reach another inspector's items. This file
-- covers the slice that adds item CRUD: every operation the app performs, for
-- both the owner (must succeed) and a non-owner (must fail), including the
-- resolve/reopen transition.
--
-- Item ownership derives entirely through the parent inspection — there is no
-- inspector_id on inspection_items — so these assertions are what prove the
-- indirection actually holds.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------- as owner (A)
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select lives_ok(
  $$insert into public.inspection_items (id, inspection_id, sort_order, title, severity)
    values ('c1000000-0000-4000-8000-0000000000aa',
            'a0000000-0000-4000-8000-000000000001', 9, 'Owner item', 'high')$$,
  'owner can add an item to their own inspection'
);

select is(
  (select severity::text from public.inspection_items
   where id = 'c1000000-0000-4000-8000-0000000000aa'),
  'high',
  'severity persists as one of the four accepted values'
);

select is(
  (select status::text from public.inspection_items
   where id = 'c1000000-0000-4000-8000-0000000000aa'),
  'open',
  'status defaults to open when the client omits it'
);

select lives_ok(
  $$update public.inspection_items set status = 'resolved'
    where id = 'c1000000-0000-4000-8000-0000000000aa'$$,
  'owner can resolve their own item'
);

-- Unlike inspections.status, which is one-way (D10), nothing constrains this,
-- so reopening must work. If a trigger is ever added, this fails loudly.
select lives_ok(
  $$update public.inspection_items set status = 'open'
    where id = 'c1000000-0000-4000-8000-0000000000aa'$$,
  'owner can reopen a resolved item — the transition is not one-way'
);

-- The schema has no in-review status and no minor/major severity.
select throws_ok(
  $$update public.inspection_items set status = 'in-review'
    where id = 'c1000000-0000-4000-8000-0000000000aa'$$,
  '22P02', null,
  'in-review is not a value item_status accepts'
);
select throws_ok(
  $$update public.inspection_items set severity = 'major'
    where id = 'c1000000-0000-4000-8000-0000000000aa'$$,
  '22P02', null,
  'major is not a value item_severity accepts'
);

-- ---------------------------------------------------------------- as non-owner (B)
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from public.inspection_items
   where id = 'c1000000-0000-4000-8000-0000000000aa'),
  0,
  'inspector B cannot read an item under inspector A''s inspection, even by id'
);

select throws_ok(
  $$insert into public.inspection_items (inspection_id, title)
    values ('a0000000-0000-4000-8000-000000000001', 'Planted by B')$$,
  '42501', null,
  'inspector B cannot create an item under inspector A''s inspection'
);

-- UPDATE and DELETE are denied by matching zero rows, silently, so the
-- assertion has to be made afterwards against the data.
select lives_ok(
  $$update public.inspection_items set title = 'HIJACKED', severity = 'low'
    where id = 'c1000000-0000-4000-8000-0000000000aa'$$,
  'B updating A''s item does not raise'
);
select lives_ok(
  $$delete from public.inspection_items
    where id = 'c1000000-0000-4000-8000-0000000000aa'$$,
  'B deleting A''s item does not raise'
);

-- ...and nothing actually changed.
reset role;
select is(
  (select title from public.inspection_items
   where id = 'c1000000-0000-4000-8000-0000000000aa'),
  'Owner item',
  'inspector A''s item was not modified by B'
);
select is(
  (select severity::text from public.inspection_items
   where id = 'c1000000-0000-4000-8000-0000000000aa'),
  'high',
  'inspector A''s item severity was not modified by B'
);
select is(
  (select count(*)::int from public.inspection_items
   where id = 'c1000000-0000-4000-8000-0000000000aa'),
  1,
  'inspector A''s item was not deleted by B'
);

-- ---------------------------------------------------------------- owner deletes
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select lives_ok(
  $$delete from public.inspection_items
    where id = 'c1000000-0000-4000-8000-0000000000aa'$$,
  'owner can delete their own item'
);

reset role;
select is(
  (select count(*)::int from public.inspection_items
   where id = 'c1000000-0000-4000-8000-0000000000aa'),
  0,
  'the owner delete actually removed it'
);

select * from finish();
rollback;
