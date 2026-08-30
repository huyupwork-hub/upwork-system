-- Private storage bucket for inspection photos.
--
-- Layout:  inspection-photos/{inspector_id}/{inspection_id}/{item_id}/{photo_id}.{ext}
--
-- The first path segment is the owner's auth.uid(), so the ownership rule is a prefix
-- comparison with no join — the same model as the database, not a second model that has
-- to be kept in agreement.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'inspection-photos',
  'inspection-photos',
  false,                                              -- private; served via signed URLs
  10485760,                                           -- 10 MB, matches item_photos.byte_size
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

-- ---------------------------------------------------------------- owner

create policy "inspection photos: owner read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "inspection photos: owner upload" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "inspection photos: owner update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "inspection photos: owner delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ---------------------------------------------------------------- admin, submitted only
--
-- Segment [2] is the inspection id. It is compared as text against a subquery of
-- id::text rather than cast to uuid: a malformed object name would make a ::uuid cast
-- raise inside the policy instead of simply denying. Comparing text fails closed.
-- The subquery is itself under RLS, so it can only ever yield submitted inspections.

create policy "inspection photos: admin read submitted" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'inspection-photos'
    and public.is_admin()
    and (storage.foldername(name))[2] in (
      select i.id::text from public.inspections i where i.status = 'submitted'
    )
  );

-- No admin write policy (D3). No anon policy of any kind.
