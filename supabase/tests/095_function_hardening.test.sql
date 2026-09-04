-- Function hardening: no EXECUTE for client roles, pinned search_path on the two trigger
-- functions that lacked it, and the triggers still doing their job afterwards.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------- execute is withdrawn
-- Written with has_function_privilege rather than by calling the functions: a direct call
-- fails with 0A000 whether or not EXECUTE was revoked, so calling proves nothing.

select ok(
  not pg_catalog.has_function_privilege('authenticated', 'public.handle_new_user()', 'execute'),
  'authenticated cannot execute handle_new_user()'
);
select ok(
  not pg_catalog.has_function_privilege('anon', 'public.handle_new_user()', 'execute'),
  'anon cannot execute handle_new_user()'
);
select ok(
  not pg_catalog.has_function_privilege('authenticated', 'public.set_updated_at()', 'execute'),
  'authenticated cannot execute set_updated_at()'
);
select ok(
  not pg_catalog.has_function_privilege('anon', 'public.set_updated_at()', 'execute'),
  'anon cannot execute set_updated_at()'
);
select ok(
  not pg_catalog.has_function_privilege('authenticated', 'public.enforce_submission_transition()', 'execute'),
  'authenticated cannot execute enforce_submission_transition()'
);
select ok(
  not pg_catalog.has_function_privilege('anon', 'public.enforce_submission_transition()', 'execute'),
  'anon cannot execute enforce_submission_transition()'
);

-- is_admin() is the counter-example: authenticated must keep it, because the policies call it.
select ok(
  pg_catalog.has_function_privilege('authenticated', 'public.is_admin()', 'execute'),
  'authenticated keeps execute on is_admin(), which the policies depend on'
);
select ok(
  not pg_catalog.has_function_privilege('anon', 'public.is_admin()', 'execute'),
  'anon cannot execute is_admin()'
);

-- ---------------------------------------------------------------- search_path is pinned

select ok(
  (select proconfig from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'set_updated_at')
  @> array['search_path='],
  'set_updated_at() pins an empty search_path'
);

select ok(
  (select proconfig from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'enforce_submission_transition')
  @> array['search_path='],
  'enforce_submission_transition() pins an empty search_path'
);

select ok(
  (select proconfig from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'handle_new_user')
  @> array['search_path='],
  'handle_new_user() still pins an empty search_path'
);

-- ---------------------------------------------------------------- the triggers still fire
-- The revoke is the risk here: if EXECUTE were checked at fire time rather than at CREATE
-- TRIGGER time, every write below would fail. They are the proof that it is not.

set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

update public.inspections
   set site_name = 'Harbour View Apartments (renamed)'
 where id = 'a0000000-0000-4000-8000-000000000001';

select ok(
  (select updated_at from public.inspections
    where id = 'a0000000-0000-4000-8000-000000000001') > timestamptz '2026-08-22 14:00:00+00',
  'set_updated_at() still stamps updated_at after the revoke'
);

-- Submission still stamps submitted_at server-side.
update public.inspections
   set status = 'submitted'
 where id = 'a0000000-0000-4000-8000-000000000001';

select isnt(
  (select submitted_at from public.inspections
    where id = 'a0000000-0000-4000-8000-000000000001'),
  null,
  'enforce_submission_transition() still stamps submitted_at after the revoke'
);

-- And submission is still one-way.
select throws_ok(
  $$update public.inspections set status = 'draft'
     where id = 'a0000000-0000-4000-8000-000000000001'$$,
  '23514', null,
  'enforce_submission_transition() still refuses to return a submitted inspection to draft'
);

reset role;

select * from finish();
rollback;
