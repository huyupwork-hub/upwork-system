-- Self-signup is closed at the database, not only at the Auth service.
--
-- The hosted project was serving `"disable_signup": false` on /auth/v1/settings, and
-- profiles.role defaults to 'inspector': any stranger could create an account, receive a
-- profile from on_auth_user_created, and then write their own inspections, items and
-- photos under the inspector policies. Turning the Auth toggle off closes that, but the
-- toggle lives in project configuration rather than in this repository. It is not visible
-- in a diff, not restored by a migration, and not proven by any test.
--
-- So there are two independent refusals, the same shape as the console's authorisation
-- gate sitting over RLS: remove the Auth toggle and the trigger still refuses; remove the
-- trigger and the toggle still refuses. Neither alone is the security model.

create table if not exists public.signup_allowlist (
  email      text primary key,
  note       text,
  created_at timestamptz not null default now()
);

comment on table public.signup_allowlist is
  'Addresses permitted to complete signup. Unreachable from anon and authenticated: '
  'provisioning an account is a privileged act, performed with the service role.';

alter table public.signup_allowlist enable row level security;
alter table public.signup_allowlist force  row level security;

-- No policy is written here on purpose. With RLS forced and no policy present the table is
-- denied to every client role by absence rather than by rule, which is the default-deny
-- posture the rest of the schema already uses. The REVOKE is defence in depth beneath it.
revoke all on public.signup_allowlist from anon, authenticated;

-- Seeded with the accounts that already exist, so the gate closes on strangers without
-- closing on the fixtures CI depends upon or on the two deliberately published demo
-- accounts. Idempotent: re-running this migration adds nothing and removes nothing.
insert into public.signup_allowlist (email, note) values
  ('inspector.a@fieldproof.test',           'local and CI fixture, created by seed.sql'),
  ('inspector.b@fieldproof.test',           'local and CI fixture, created by seed.sql'),
  ('admin@fieldproof.test',                 'local and CI fixture, created by seed.sql'),
  ('fieldproof-demo-inspector@yopmail.com', 'published demo inspector, docs/DEMO.md'),
  ('fieldproof-demo-admin@yopmail.com',     'published demo admin, docs/DEMO.md')
on conflict (email) do nothing;

-- handle_new_user() gains the gate ahead of the insert it already performed.
--
-- Raising here aborts the INSERT on auth.users in the same transaction, so a refused
-- signup leaves nothing behind: no auth row without a profile, a state the application has
-- no handling for. Refusing late and cleanly beats refusing early and stranding an
-- account. A null email — a phone or anonymous signup — matches nothing and is refused,
-- which is the right default for a deployment that provisions explicitly.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.signup_allowlist a
    where lower(a.email) = lower(new.email)
  ) then
    raise exception 'signup is closed'
      using errcode = '42501',
            detail  = 'This deployment provisions accounts explicitly. Self-signup is not available.';
  end if;

  insert into public.profiles (id, full_name)
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
      split_part(coalesce(new.email, 'inspector'), '@', 1)
    )
  );
  return new;
end;
$$;

-- CREATE OR REPLACE hands EXECUTE back to PUBLIC, undoing the revoke in
-- 20260905000600_function_hardening.sql. Re-applied here so the two migrations compose
-- in either order of reading.
revoke all on function public.handle_new_user() from public, anon, authenticated;
