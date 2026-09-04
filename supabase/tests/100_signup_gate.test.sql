-- The signup gate: a stranger cannot provision an account, an allowlisted address still
-- can, and the allowlist itself is not readable or writable by any client role.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------- the gate refuses
-- Written as a direct insert on auth.users because that is what GoTrue does on signup;
-- the trigger cannot tell the two apart, which is the point.

select throws_ok(
  $$insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data,
      confirmation_token, recovery_token, email_change, email_change_token_new
    ) values (
      '00000000-0000-0000-0000-000000000000', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      'authenticated', 'authenticated', 'stranger@example.com', 'x',
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}', '{"full_name":"Stranger"}',
      '', '', '', '')$$,
  '42501', null,
  'a stranger cannot complete signup'
);

-- The refusal aborts the auth.users insert too, so nothing half-provisioned survives it.
select is_empty(
  $$select 1 from public.profiles where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'$$,
  'a refused signup leaves no profile behind'
);
select is_empty(
  $$select 1 from auth.users where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'$$,
  'a refused signup leaves no auth user behind'
);

-- Case is not a way around it.
select throws_ok(
  $$insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data,
      confirmation_token, recovery_token, email_change, email_change_token_new
    ) values (
      '00000000-0000-0000-0000-000000000000', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      'authenticated', 'authenticated', 'STRANGER@example.com', 'x',
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}', '{}',
      '', '', '', '')$$,
  '42501', null,
  'signup is refused regardless of the case of the address'
);

-- ---------------------------------------------------------------- the gate admits
-- A gate, not a wall: an allowlisted address provisions exactly as before.

insert into public.signup_allowlist (email, note)
values ('inspector.c@fieldproof.test', 'provisioned inside this test only');

select lives_ok(
  $$insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data,
      confirmation_token, recovery_token, email_change, email_change_token_new
    ) values (
      '00000000-0000-0000-0000-000000000000', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'authenticated', 'authenticated', 'inspector.c@fieldproof.test', 'x',
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}', '{"full_name":"Inspector Charlie"}',
      '', '', '', '')$$,
  'an allowlisted address still completes signup'
);

select is(
  (select full_name from public.profiles where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  'Inspector Charlie',
  'the admitted signup received its profile from the trigger'
);

select is(
  (select role::text from public.profiles where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  'inspector',
  'a provisioned account is an inspector, never an admin, by default'
);

-- ---------------------------------------------------------------- the allowlist is private
-- Denied by absence of a policy, and by the REVOKE beneath it. An inspector who could read
-- this table would learn which addresses exist; one who could write it could let itself in.

set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$select 1 from public.signup_allowlist$$,
  '42501', null,
  'an inspector cannot read the signup allowlist'
);

select throws_ok(
  $$insert into public.signup_allowlist (email) values ('attacker@example.com')$$,
  '42501', null,
  'an inspector cannot add itself to the signup allowlist'
);

select throws_ok(
  $$delete from public.signup_allowlist$$,
  '42501', null,
  'an inspector cannot empty the signup allowlist'
);

reset role;

select * from finish();
rollback;
