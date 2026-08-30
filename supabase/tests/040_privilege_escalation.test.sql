-- A5 / D4: a user cannot become an admin, and anon reaches nothing.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------- self-escalation
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select ok(not public.is_admin(), 'an inspector does not resolve as admin');

-- Blocked by column privilege (D4), beneath RLS — error class 42501.
select throws_ok(
  $$update public.profiles set role = 'admin'
    where id = '11111111-1111-4111-8111-111111111111'$$,
  '42501', null,
  'an inspector cannot escalate their own role to admin'
);

-- Escalating someone else fails too.
select throws_ok(
  $$update public.profiles set role = 'admin'
    where id = '22222222-2222-4222-8222-222222222222'$$,
  '42501', null,
  'an inspector cannot escalate another user''s role'
);

-- The legitimate profile edit still works — the revoke is column-scoped, not blanket.
select lives_ok(
  $$update public.profiles set full_name = 'Inspector Alpha Renamed'
    where id = '11111111-1111-4111-8111-111111111111'$$,
  'an inspector can still rename themselves'
);

-- profiles is not readable across users
select is((select count(*)::int from public.profiles), 1,
  'an inspector sees only their own profile row');

reset role;
select is((select role::text from public.profiles where id = '11111111-1111-4111-8111-111111111111'),
  'inspector', 'role is still inspector after every escalation attempt');

-- ---------------------------------------------------------------- A4: anon
--
-- anon holds no table privilege at all, so these RAISE 42501 rather than returning an
-- empty set. That is the stricter outcome: the request is refused before RLS is even
-- consulted. Asserting "returns 0 rows" here would be wrong, and would fail.
set local role anon;

select throws_ok($$select 1 from public.inspections$$,      '42501', null, 'anon cannot read inspections');
select throws_ok($$select 1 from public.inspection_items$$, '42501', null, 'anon cannot read items');
select throws_ok($$select 1 from public.item_photos$$,      '42501', null, 'anon cannot read photos');
select throws_ok($$select 1 from public.profiles$$,         '42501', null, 'anon cannot read profiles');

select throws_ok(
  $$insert into public.inspections (inspector_id, site_name, inspection_date)
    values ('11111111-1111-4111-8111-111111111111', 'Anon Site', date '2026-08-25')$$,
  '42501', null,
  'anon cannot insert an inspection'
);

select * from finish();
rollback;
