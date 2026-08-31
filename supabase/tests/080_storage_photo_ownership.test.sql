-- Storage object ownership, and the metadata that must agree with it.
--
-- The database enforces ownership twice, and both halves matter:
--   * `item_photos` rows, through the parent inspection
--   * `storage.objects`, through path segment [1] compared to auth.uid()
--
-- A photo is only safe if both hold. A metadata row the caller may write but an
-- object they may not (or the reverse) would be a hole, so this file asserts the
-- storage half specifically — `060`/`070` cover the metadata half.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- The bucket must never become public. A public bucket would make every policy
-- below irrelevant, because the object URL alone would be enough.
select is(
  (select public from storage.buckets where id = 'inspection-photos'),
  false,
  'the inspection-photos bucket is private'
);

-- ---------------------------------------------------------------- as inspector A
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select lives_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('inspection-photos',
            '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000001/a1000000-0000-4000-8000-000000000001/own.jpg')$$,
  'an inspector can upload under their own uid and their own draft'
);

-- Segment [1] is the owner. Writing under another inspector's prefix is the
-- attack this policy exists to stop, and it must fail even though the rest of
-- the path is well formed.
select throws_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('inspection-photos',
            '22222222-2222-4222-8222-222222222222/b0000000-0000-4000-8000-000000000001/b1000000-0000-4000-8000-000000000001/forged.jpg')$$,
  '42501', null,
  'an inspector cannot upload under another inspector''s prefix'
);

-- Own prefix, but someone else's inspection in segment [2].
select throws_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('inspection-photos',
            '11111111-1111-4111-8111-111111111111/b0000000-0000-4000-8000-000000000001/b1000000-0000-4000-8000-000000000001/mixed.jpg')$$,
  '42501', null,
  'an inspector cannot upload under an inspection they do not own'
);

-- D17: own prefix, own inspection, but that inspection is submitted.
select throws_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('inspection-photos',
            '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/a1000000-0000-4000-8000-000000000002/late.jpg')$$,
  '42501', null,
  'D17: an object cannot be added under a submitted inspection'
);

select is(
  (select count(*)::int from storage.objects
   where bucket_id = 'inspection-photos'
     and name like '11111111%'),
  1,
  'the inspector sees their own object'
);

-- ---------------------------------------------------------------- as inspector B
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from storage.objects
   where bucket_id = 'inspection-photos'
     and name like '11111111%'),
  0,
  'inspector B cannot list inspector A''s objects'
);

-- Denied silently by matching nothing, as ever.
select lives_ok(
  $$delete from storage.objects
    where bucket_id = 'inspection-photos' and name like '11111111%'$$,
  'B deleting A''s object does not raise'
);

reset role;
select is(
  (select count(*)::int from storage.objects
   where bucket_id = 'inspection-photos' and name like '11111111%'),
  1,
  'inspector A''s object was not deleted by B'
);

-- ---------------------------------------------------------------- metadata agrees
--
-- The metadata row must not be able to describe an object the caller could not
-- have written. These two are what stop a row pointing at a cross-owner path.

set local request.jwt.claims = '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$insert into public.item_photos
      (item_id, inspection_id, storage_path, content_type, byte_size)
    values ('a1000000-0000-4000-8000-000000000001',
            'a0000000-0000-4000-8000-000000000001',
            '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000001/a1000000-0000-4000-8000-000000000001/stolen.jpg',
            'image/jpeg', 1024)$$,
  '42501', null,
  'B cannot write metadata describing an object under A''s inspection'
);

-- ---------------------------------------------------------------- owner deletes
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

select lives_ok(
  $$delete from storage.objects
    where bucket_id = 'inspection-photos' and name like '11111111%'$$,
  'the owner can delete their own object while the inspection is a draft'
);

reset role;
select is(
  (select count(*)::int from storage.objects
   where bucket_id = 'inspection-photos' and name like '11111111%'),
  0,
  'the owner delete actually removed it'
);

-- ---------------------------------------------------------------- admin reads
--
-- D3 unchanged: an admin reads objects under submitted inspections only. There
-- is no admin write policy on storage at all.

select is(
  (select count(*)::int from pg_policies
   where schemaname = 'storage'
     and cmd <> 'SELECT'
     and coalesce(qual, '') || coalesce(with_check, '') like '%is_admin%'),
  0,
  'no admin write policy exists on storage.objects'
);

select * from finish();
rollback;
