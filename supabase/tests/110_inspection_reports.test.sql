-- D21 amended / D31: one write-once report object per submitted inspection.
--
-- Denial shapes, as in 070: INSERT violating WITH CHECK raises 42501; a second INSERT at
-- the pinned name raises 23505 from the unique index; UPDATE with no policy matches zero
-- rows silently (or 42501 if the stack holds no grant -- absorbed, and the re-read is the
-- proof). DELETE cannot be exercised here at all: storage.protect_delete(), see 080. It is
-- proven by the zero policy count below and by hosted smoke 22b through the Storage API.
--
-- Order matters for two of the assertions and is the opposite of what the index name
-- suggests: Postgres evaluates the RLS WITH CHECK before the heap insert and the unique
-- index only after it. So the owner's duplicate passes the policy and THEN gets 23505,
-- while B and the admin, whom the policy refuses, get 42501 at the very same name even
-- though it is already taken -- the index is never reached for them.
--
-- Authored on a machine with no Postgres (D1), as 095 was; CI is the arbiter. Fixtures
-- are the seed's: inspector A owns DRAFT_A (a0…01) and SUBMITTED_A (a0…02), inspector B
-- owns one draft, the admin owns nothing.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------- posture

-- Private, or every policy below is irrelevant (080 says the same of the photo bucket).
select is((select public from storage.buckets where id = 'inspection-reports'), false,
  'the inspection-reports bucket is private');
select is((select allowed_mime_types from storage.buckets where id = 'inspection-reports'),
  array['application/pdf']::text[], 'the inspection-reports bucket accepts PDF only');
select is((select file_size_limit from storage.buckets where id = 'inspection-reports'),
  52428800::bigint, 'the inspection-reports bucket caps an object at 50 MB');

-- The write-once claim leans on this index; if Storage ever dropped it, one name could
-- hold two objects and the second insert below would live. Newer storage-api versions
-- carry idx_objects_bucket_id_name on (bucket_id, name COLLATE "C") beside -- or instead
-- of -- the original bucketid_objname on (bucket_id, name); either spelling is the same
-- uniqueness fact, so both are accepted.
select ok(exists (
  select 1 from pg_indexes
   where schemaname = 'storage' and tablename = 'objects'
     and indexdef ~* 'unique' and indexdef ~* '\(bucket_id, name( collate "c")?\)'),
  'storage.objects is unique on (bucket_id, name)');

-- Write-once by absence: the count is the assertion. pg_policies renders the bucket
-- literal inside every qualifier as bucket_id = 'inspection-reports'::text, so the LIKE
-- picks out exactly the policies that name this bucket.
select is((select count(*)::int from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and cmd in ('UPDATE', 'DELETE')
     and coalesce(qual, '') || coalesce(with_check, '') like '%inspection-reports%'), 0,
  'no UPDATE or DELETE policy names the reports bucket');
select is((select count(*)::int from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and cmd = 'INSERT'
     and coalesce(with_check, '') like '%inspection-reports%'), 1,
  'exactly one INSERT policy names the reports bucket');
select is((select count(*)::int from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and cmd = 'SELECT'
     and coalesce(qual, '') like '%inspection-reports%'), 2,
  'two SELECT policies name the reports bucket: owner, and admin under submitted');

-- ---------------------------------------------------------------- as inspector A
-- A owns DRAFT_A (a0…01) and SUBMITTED_A (a0…02).
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select lives_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/report.pdf')$$,
  'the owner can publish the report of their own submitted inspection');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/report.pdf')$$,
  '23505', null, 'a second object under the same name is refused: one report per inspection');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/report-v2.pdf')$$,
  '42501', null, 'only the fixed name report.pdf is writable; nothing can be added beside it');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/x/report.pdf')$$,
  '42501', null, 'nor deeper than it');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000001/report.pdf')$$,
  '42501', null, 'D21: a draft cannot have a stored report');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/b0000000-0000-4000-8000-000000000001/report.pdf')$$,
  '42501', null, 'an inspector cannot publish under an inspection they do not own');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '22222222-2222-4222-8222-222222222222/a0000000-0000-4000-8000-000000000002/report.pdf')$$,
  '42501', null, 'the owner segment cannot be forged either');
-- D17 untouched: the photo bucket still refuses any write under a submitted inspection.
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-photos',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/report.pdf')$$,
  '42501', null, 'a report cannot be smuggled into the photo bucket under a submitted inspection');

-- No UPDATE policy names this bucket, so the row is filtered out before anything runs.
-- Whether the stack also grants authenticated UPDATE on storage.objects decides silence
-- versus 42501; the DO block absorbs the second shape and the privileged re-read below
-- is the proof either way.
select lives_ok($$
  do $b$
  begin
    update storage.objects set name = 'renamed.pdf' where bucket_id = 'inspection-reports';
  exception when insufficient_privilege then
    null;  -- no grant at all is the same conclusion; the re-read below is the proof
  end
  $b$
$$, 'an update to a stored report is refused silently, or for want of any grant');
select is((select count(*)::int from storage.objects where bucket_id = 'inspection-reports'),
  1, 'the owner reads their own stored report');

reset role;
select is((select count(*)::int from storage.objects where bucket_id = 'inspection-reports'
   and name = '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/report.pdf'),
  1, 'and the update changed nothing');

-- ---------------------------------------------------------------- as inspector B
set local request.jwt.claims = '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local role authenticated;

select is((select count(*)::int from storage.objects where bucket_id = 'inspection-reports'),
  0, 'inspector B cannot list inspector A''s report');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/report.pdf')$$,
  '42501', null, 'inspector B cannot forge a report under A''s path');

-- ---------------------------------------------------------------- planted, privileged
-- No client policy can create either of these; the admin read policy must fail closed on
-- them anyway (the pattern 095 uses: plant what the model forbids, then observe).
reset role;
insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000001/report.pdf');
insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/planted.pdf');

-- ---------------------------------------------------------------- as admin
set local request.jwt.claims = '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local role authenticated;

select is((select count(*)::int from storage.objects where bucket_id = 'inspection-reports'),
  1, 'D3: the admin reads exactly the pinned report under the submitted inspection');
-- Aggregated rather than a bare scalar subquery: were the count above ever wrong, a second
-- row would make a scalar subquery raise and abort the file instead of failing this one.
select is((select string_agg(name, ',' order by name) from storage.objects
   where bucket_id = 'inspection-reports'),
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/report.pdf',
  'and it is that one -- not the planted draft object, not the planted sibling');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/report.pdf')$$,
  '42501', null, 'D23: an admin cannot publish a report');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('inspection-reports',
  '33333333-3333-4333-8333-333333333333/a0000000-0000-4000-8000-000000000002/report.pdf')$$,
  '42501', null, 'nor under their own prefix: an admin owns no submitted inspection');
select lives_ok($$
  do $b$
  begin
    update storage.objects set name = 'x' where bucket_id = 'inspection-reports';
  exception when insufficient_privilege then null;
  end
  $b$
$$, 'an admin update is refused silently, or for want of any grant');
select is((select count(*)::int from public.inspections
   where id = 'a0000000-0000-4000-8000-000000000002'), 1,
  'D3 is unchanged: an admin still reads the submitted inspection');

reset role;
select is((select count(*)::int from storage.objects where bucket_id = 'inspection-reports'
   and name like '%/report.pdf'), 2, 'and the admin update changed nothing');

-- ---------------------------------------------------------------- anon
set local role anon;
select throws_ok($$insert into storage.objects (bucket_id, name)
  values ('inspection-reports', 'x/y/report.pdf')$$,
  '42501', null, 'anon cannot publish a report');
reset role;

select * from finish();
rollback;
