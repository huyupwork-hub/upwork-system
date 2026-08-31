-- A submitted inspection is immutable (D17).
--
-- Until now, submission gated *visibility* (D3: admins read submitted work) but
-- not *mutability* — an owner could keep editing a submitted inspection and its
-- items, so what an admin reviewed could change underneath them. This makes
-- submission the point at which the record is fixed.
--
-- Enforced here, in the database, not in Flutter. A UI-only lock would leave the
-- write path open to any client holding a valid JWT.
--
-- Scope:
--   * inspections      UPDATE only while draft; DELETE only while draft
--   * inspection_items INSERT/UPDATE/DELETE only while the parent is draft
--   * item_photos      INSERT/UPDATE/DELETE only while the parent is draft
--   * storage objects  write only under a draft inspection
--   * SELECT is untouched everywhere; submitted work stays readable
--   * admin behaviour is untouched (still read-only, still submitted-only)
--
-- There is no reopen/unsubmit workflow in V1.

-- ---------------------------------------------------------------- inspections

drop policy if exists inspections_update_own on public.inspections;
drop policy if exists inspections_delete_own on public.inspections;

-- USING is evaluated against the OLD row, WITH CHECK against the NEW one. So
-- `using (status = 'draft')` still permits the draft -> submitted transition
-- itself, while refusing every update to an already-submitted row. WITH CHECK
-- must NOT require draft, or submitting would deny itself.
create policy inspections_update_own on public.inspections
  for update to authenticated
  using (
    inspector_id = (select auth.uid())
    and status = 'draft'
    and not public.is_admin()
  )
  with check (
    inspector_id = (select auth.uid())
    and not public.is_admin()
  );

create policy inspections_delete_own on public.inspections
  for delete to authenticated
  using (
    inspector_id = (select auth.uid())
    and status = 'draft'
    and not public.is_admin()
  );

-- ---------------------------------------------------------------- items

drop policy if exists inspection_items_insert_own on public.inspection_items;
drop policy if exists inspection_items_update_own on public.inspection_items;
drop policy if exists inspection_items_delete_own on public.inspection_items;

create policy inspection_items_insert_own on public.inspection_items
  for insert to authenticated
  with check (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
      and i.status = 'draft'
  ));

create policy inspection_items_update_own on public.inspection_items
  for update to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
      and i.status = 'draft'
  ))
  with check (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
      and i.status = 'draft'
  ));

create policy inspection_items_delete_own on public.inspection_items
  for delete to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
      and i.status = 'draft'
  ));

-- ---------------------------------------------------------------- photos

drop policy if exists item_photos_insert_own on public.item_photos;
drop policy if exists item_photos_update_own on public.item_photos;
drop policy if exists item_photos_delete_own on public.item_photos;

create policy item_photos_insert_own on public.item_photos
  for insert to authenticated
  with check (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
      and i.status = 'draft'
  ));

create policy item_photos_update_own on public.item_photos
  for update to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
      and i.status = 'draft'
  ))
  with check (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
      and i.status = 'draft'
  ));

create policy item_photos_delete_own on public.item_photos
  for delete to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
      and i.status = 'draft'
  ));

-- ---------------------------------------------------------------- storage
--
-- Reads stay as they were. Writes additionally require the inspection named by
-- path segment [2] to be one of the caller's own drafts, so a storage object
-- cannot be added or removed under submitted work — which is what keeps the
-- bucket consistent with the metadata rows above.

drop policy if exists "inspection photos: owner upload" on storage.objects;
drop policy if exists "inspection photos: owner update" on storage.objects;
drop policy if exists "inspection photos: owner delete" on storage.objects;

create policy "inspection photos: owner upload" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (storage.foldername(name))[2] in (
      select i.id::text from public.inspections i
      where i.inspector_id = (select auth.uid()) and i.status = 'draft'
    )
  );

create policy "inspection photos: owner update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (storage.foldername(name))[2] in (
      select i.id::text from public.inspections i
      where i.inspector_id = (select auth.uid()) and i.status = 'draft'
    )
  )
  with check (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (storage.foldername(name))[2] in (
      select i.id::text from public.inspections i
      where i.inspector_id = (select auth.uid()) and i.status = 'draft'
    )
  );

create policy "inspection photos: owner delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'inspection-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (storage.foldername(name))[2] in (
      select i.id::text from public.inspections i
      where i.inspector_id = (select auth.uid()) and i.status = 'draft'
    )
  );

comment on policy inspections_update_own on public.inspections is
  'Draft-only. USING sees the OLD row, so submitting is still permitted; editing a submitted row is not (D17).';
