-- D17: a submitted inspection is immutable.
--
-- The seed's SUBMITTED_A ('a0000000-…0002') is the fixture: it already has two
-- items and one photo, so every write path can be attempted against real
-- children rather than rows this file has to invent.
--
-- Two denial shapes again, and they differ by operation:
--   INSERT violating WITH CHECK  -> raises 42501
--   UPDATE/DELETE failing USING  -> matches zero rows, silently
-- Every silent case is followed by a privileged re-read proving nothing moved.
--
-- What must NOT break: reads. Submitted work stays readable to its owner and,
-- per D3, to admins. A gate that also hid the data would be a different bug.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

-- ---------------------------------------------------------------- still readable

select is(
  (select count(*)::int from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000002'),
  1,
  'the owner can still read their submitted inspection'
);
select is(
  (select count(*)::int from public.inspection_items
   where inspection_id = 'a0000000-0000-4000-8000-000000000002'),
  2,
  'the owner can still read its items'
);
select is(
  (select count(*)::int from public.item_photos
   where inspection_id = 'a0000000-0000-4000-8000-000000000002'),
  1,
  'the owner can still read its photos'
);

-- ---------------------------------------------------------------- the inspection

select lives_ok(
  $$update public.inspections set site_name = 'EDITED AFTER SUBMIT'
    where id = 'a0000000-0000-4000-8000-000000000002'$$,
  'editing a submitted inspection does not raise'
);
select lives_ok(
  $$delete from public.inspections
    where id = 'a0000000-0000-4000-8000-000000000002'$$,
  'deleting a submitted inspection does not raise'
);

-- ---------------------------------------------------------------- its items

select throws_ok(
  $$insert into public.inspection_items (inspection_id, title)
    values ('a0000000-0000-4000-8000-000000000002', 'Added after submit')$$,
  '42501', null,
  'a new item cannot be added under a submitted inspection'
);

select lives_ok(
  $$update public.inspection_items set title = 'EDITED AFTER SUBMIT'
    where id = 'a1000000-0000-4000-8000-000000000002'$$,
  'editing an item under a submitted inspection does not raise'
);

-- Resolve/reopen is a status update like any other, and is equally refused.
select lives_ok(
  $$update public.inspection_items set status = 'resolved'
    where id = 'a1000000-0000-4000-8000-000000000002'$$,
  'resolving an item under a submitted inspection does not raise'
);

select lives_ok(
  $$delete from public.inspection_items
    where id = 'a1000000-0000-4000-8000-000000000002'$$,
  'deleting an item under a submitted inspection does not raise'
);

-- ---------------------------------------------------------------- its photos

select throws_ok(
  $$insert into public.item_photos
      (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('a1000000-0000-4000-8000-000000000002',
            'a0000000-0000-4000-8000-000000000002',
            'late/addition/after/submit.jpg', 'image/jpeg', 1024)$$,
  '42501', null,
  'a photo cannot be added under a submitted inspection'
);

select lives_ok(
  $$delete from public.item_photos
    where id = 'a2000000-0000-4000-8000-000000000002'$$,
  'deleting a photo under a submitted inspection does not raise'
);

-- ---------------------------------------------------------------- nothing moved

reset role;

select is(
  (select site_name from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000002'),
  'Northgate Retail Park',
  'the submitted inspection was not edited'
);
select is(
  (select count(*)::int from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000002'),
  1,
  'the submitted inspection was not deleted'
);
select is(
  (select title from public.inspection_items
   where id = 'a1000000-0000-4000-8000-000000000002'),
  'Exposed wiring at junction box',
  'its item was not edited'
);
select is(
  (select status::text from public.inspection_items
   where id = 'a1000000-0000-4000-8000-000000000002'),
  'open',
  'its item was not resolved'
);
select is(
  (select count(*)::int from public.inspection_items
   where inspection_id = 'a0000000-0000-4000-8000-000000000002'),
  2,
  'no item was deleted'
);
select is(
  (select count(*)::int from public.item_photos
   where id = 'a2000000-0000-4000-8000-000000000002'),
  1,
  'its photo was not deleted'
);

-- ---------------------------------------------------------------- drafts unaffected
--
-- The gate must bite on submitted work only. If it also froze drafts the app
-- would be unusable, and these assertions would catch that.

set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select lives_ok(
  $$update public.inspections set site_name = 'Draft still editable'
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'a draft inspection is still editable'
);
select is(
  (select site_name from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000001'),
  'Draft still editable',
  'the draft edit actually applied'
);

select lives_ok(
  $$insert into public.inspection_items (inspection_id, title)
    values ('a0000000-0000-4000-8000-000000000001', 'Still addable')$$,
  'items can still be added under a draft'
);

-- And submitting a draft still works: D17 freezes the row *after* the
-- transition, it does not prevent the transition itself.
select lives_ok(
  $$update public.inspections set status = 'submitted'
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'a draft can still be submitted'
);
select is(
  (select status::text from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000001'),
  'submitted',
  'the submission actually applied'
);

-- ...and is immutable from that moment.
select lives_ok(
  $$update public.inspections set site_name = 'AFTER'
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'editing the freshly submitted inspection does not raise'
);
select is(
  (select site_name from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000001'),
  'Draft still editable',
  'the freshly submitted inspection is immutable immediately'
);

-- ---------------------------------------------------------------- admin unchanged

reset role;
set local request.jwt.claims = '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000002'),
  1,
  'D3 is unchanged: an admin still reads submitted inspections'
);

select * from finish();
rollback;
