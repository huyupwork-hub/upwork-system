-- Search: ownership, and a deterministic order.
--
-- Search runs against the stored `search_tsv` and its GIN index (DATA_MODEL §7),
-- so it is an ordinary SELECT and RLS applies to it exactly as it does to the
-- history list. That is the property worth asserting: a query cannot become a
-- way to discover rows the caller could not otherwise read.
--
-- The client sends prefix terms (`north:*`), so these use the same shape.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------- as inspector A
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local role authenticated;

-- Seed gives A two inspections (Harbour View, Northgate Retail Park) and B one
-- (Riverside Depot).

select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'northgate:*')),
  1,
  'A can find their own inspection by site name'
);

select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'dock:*')),
  1,
  'A can find their own inspection by address'
);

select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'meridian:*')),
  1,
  'A can find their own inspection by client name'
);

-- 'simple' lowercases what it indexes, so case never has to be handled by the
-- client.
select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'NORTHGATE:*')),
  1,
  'search is case-insensitive'
);

-- Prefix matching is what the tsvector design supports, and what the client
-- sends. Whole-word-only search would make the field feel broken while typing.
select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'north:*')),
  1,
  'a prefix matches without the whole word'
);

-- Both lifecycle states are searchable: submitting an inspection must not make
-- it disappear from its owner's search.
select is(
  (select count(*)::int from public.inspections
   where status = 'draft' and search_tsv @@ to_tsquery('simple', 'harbour:*')),
  1,
  'a draft is searchable'
);
select is(
  (select count(*)::int from public.inspections
   where status = 'submitted'
     and search_tsv @@ to_tsquery('simple', 'northgate:*')),
  1,
  'a submitted inspection is searchable'
);

-- ---------------------------------------------------------------- the isolation case
--
-- B's inspection carries a term that appears nowhere in A's rows. If search
-- could reach past RLS, this is where it would show.

select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'riverside:*')),
  0,
  'A searching for a term unique to B''s inspection finds nothing'
);
select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'ashcroft:*')),
  0,
  'nor by B''s client name'
);
select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'sheffield:*')),
  0,
  'nor by B''s address'
);

-- A term common to both owners must still only return the caller's own rows —
-- the case a naive "search returns nothing for B's words" test would miss.
select is(
  (select count(*)::int from public.inspections
   where inspector_id <> '11111111-1111-4111-8111-111111111111'),
  0,
  'no query can return a row owned by another inspector'
);

-- ---------------------------------------------------------------- ordering

-- inspection_date DESC, created_at DESC, id DESC — the total order the client
-- asks for. Seeded dates: Harbour View 2026-08-20, Northgate 2026-08-22.
select is(
  (select array_agg(site_name order by inspection_date desc, created_at desc, id desc)
   from public.inspections),
  array['Northgate Retail Park', 'Harbour View Apartments'],
  'history is inspection_date descending'
);

-- The tiebreak is what makes the order total. Two rows on the same date, written
-- in the same transaction, would otherwise come back in any order.
select lives_ok(
  $$insert into public.inspections
      (id, inspector_id, site_name, inspection_date)
    values
      ('d0000000-0000-4000-8000-00000000000a',
       '11111111-1111-4111-8111-111111111111', 'Tie A', date '2026-09-01'),
      ('d0000000-0000-4000-8000-00000000000b',
       '11111111-1111-4111-8111-111111111111', 'Tie B', date '2026-09-01')$$,
  'two inspections can share a date'
);

select is(
  (select array_agg(site_name order by inspection_date desc, created_at desc, id desc)
   from public.inspections
   where inspection_date = date '2026-09-01'),
  array['Tie B', 'Tie A'],
  'a same-date tie resolves by id, deterministically'
);

-- ---------------------------------------------------------------- as inspector B

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'northgate:*')),
  0,
  'B searching for a term unique to A''s inspection finds nothing'
);
select is(
  (select count(*)::int from public.inspections
   where search_tsv @@ to_tsquery('simple', 'riverside:*')),
  1,
  'B can still find their own'
);

-- ---------------------------------------------------------------- anon

reset role;
set local role anon;

select throws_ok(
  $$select 1 from public.inspections
    where search_tsv @@ to_tsquery('simple', 'northgate:*')$$,
  '42501', null,
  'search is not a way around the anon refusal'
);

select * from finish();
rollback;
