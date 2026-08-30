-- Structural and security-posture assertions.
--
-- no_plan() rather than plan(N): the suite cannot be executed on the development machine
-- (no Docker/Postgres — see D1), so a hand-counted plan would risk failing CI for an
-- off-by-one rather than for a real defect. Every assertion below still fails loudly.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- tables exist
select has_table('public', 'profiles',         'profiles exists');
select has_table('public', 'inspections',      'inspections exists');
select has_table('public', 'inspection_items', 'inspection_items exists');
select has_table('public', 'item_photos',      'item_photos exists');

-- J1: RLS enabled AND forced on every application table
select is((select relrowsecurity      from pg_class where oid = 'public.profiles'::regclass),         true, 'profiles: RLS enabled');
select is((select relforcerowsecurity from pg_class where oid = 'public.profiles'::regclass),         true, 'profiles: RLS forced');
select is((select relrowsecurity      from pg_class where oid = 'public.inspections'::regclass),      true, 'inspections: RLS enabled');
select is((select relforcerowsecurity from pg_class where oid = 'public.inspections'::regclass),      true, 'inspections: RLS forced');
select is((select relrowsecurity      from pg_class where oid = 'public.inspection_items'::regclass), true, 'inspection_items: RLS enabled');
select is((select relforcerowsecurity from pg_class where oid = 'public.inspection_items'::regclass), true, 'inspection_items: RLS forced');
select is((select relrowsecurity      from pg_class where oid = 'public.item_photos'::regclass),      true, 'item_photos: RLS enabled');
select is((select relforcerowsecurity from pg_class where oid = 'public.item_photos'::regclass),      true, 'item_photos: RLS forced');

-- Default-deny: anon is named by no policy anywhere in public.
select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and 'anon' = any(roles)),
  0,
  'no policy in public names the anon role'
);

-- J4: no policy grants unrestricted access (a bare `true` qualifier) to authenticated.
select is(
  (select count(*)::int from pg_policies
   where schemaname = 'public'
     and 'authenticated' = any(roles)
     and coalesce(qual, '') = 'true'),
  0,
  'no policy exposes a bare true USING qualifier to authenticated'
);

-- D3: admin is read-only. No write policy anywhere references is_admin().
select is(
  (select count(*)::int from pg_policies
   where schemaname = 'public'
     and cmd <> 'SELECT'
     and coalesce(qual, '') || coalesce(with_check, '') like '%is_admin%'),
  0,
  'no INSERT/UPDATE/DELETE policy references is_admin()'
);

-- D4: role is not client-writable, but the rest of the profile is.
select ok(not has_column_privilege('authenticated', 'public.profiles', 'role',      'UPDATE'), 'authenticated cannot UPDATE profiles.role');
select ok(not has_column_privilege('authenticated', 'public.profiles', 'id',        'UPDATE'), 'authenticated cannot UPDATE profiles.id');
select ok(    has_column_privilege('authenticated', 'public.profiles', 'full_name', 'UPDATE'), 'authenticated can UPDATE profiles.full_name');

-- anon holds no table privileges at all
select ok(not has_table_privilege('anon', 'public.inspections', 'SELECT'), 'anon has no SELECT privilege on inspections');
select ok(not has_table_privilege('anon', 'public.item_photos', 'SELECT'), 'anon has no SELECT privilege on item_photos');

-- D8: the composite FK that makes the denormalised inspection_id safe
select col_is_unique('public', 'inspection_items', ARRAY['id', 'inspection_id'],
  'inspection_items has the (id, inspection_id) unique constraint the photo FK targets');

-- search vector is generated, not client-supplied
select is(
  (select is_generated from information_schema.columns
   where table_schema = 'public' and table_name = 'inspections' and column_name = 'search_tsv'),
  'ALWAYS',
  'inspections.search_tsv is always-generated'
);

-- private bucket
select is((select public from storage.buckets where id = 'inspection-photos'), false,
  'inspection-photos bucket is private');

select * from finish();
rollback;
