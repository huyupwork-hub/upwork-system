-- Row Level Security. Default-deny throughout: anon has no policy on any table, so
-- anonymous access is denied by absence rather than by rule.
-- Matrix of record: docs/DATA_MODEL.md §5.

alter table public.profiles         enable row level security;
alter table public.inspections      enable row level security;
alter table public.inspection_items enable row level security;
alter table public.item_photos      enable row level security;

-- FORCE so the policies apply to the table owner too, not just to other roles.
alter table public.profiles         force row level security;
alter table public.inspections      force row level security;
alter table public.inspection_items force row level security;
alter table public.item_photos      force row level security;

-- ---------------------------------------------------------------- grants
-- Supabase grants broadly to anon/authenticated by default. Revoke first, then grant
-- back only what the model needs: defence in depth behind RLS, not instead of it.

revoke all on public.profiles, public.inspections, public.inspection_items, public.item_photos
  from anon, authenticated;

grant select on public.profiles to authenticated;

-- D4: column-scoped GRANT, not a REVOKE. A table-wide `grant update` covers every
-- column, and a later `revoke update (role)` does NOT carve it out — PostgreSQL keeps
-- table- and column-level privileges separately, so the table grant still wins.
-- Granting only the columns a user may write is the mechanism that actually holds.
grant update (full_name) on public.profiles to authenticated;
grant select, insert, update, delete on public.inspections      to authenticated;
grant select, insert, update, delete on public.inspection_items to authenticated;
grant select, insert, update, delete on public.item_photos      to authenticated;

-- ---------------------------------------------------------------- profiles

create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

-- Admins read only the profiles of inspectors who have submitted work — consistent with
-- admin visibility being scoped to submitted inspections (D3). Not a user directory.
create policy profiles_select_admin on public.profiles
  for select to authenticated
  using (
    public.is_admin()
    and exists (
      select 1 from public.inspections i
      where i.inspector_id = profiles.id and i.status = 'submitted'
    )
  );

create policy profiles_update_self on public.profiles
  for update to authenticated
  using      (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- No INSERT policy: profiles are created by trigger only.
-- No DELETE policy: profiles die with their auth.users row.

-- ---------------------------------------------------------------- inspections
-- (select auth.uid()) is wrapped deliberately: it lets the planner evaluate the call
-- once per statement rather than once per row.

create policy inspections_select_own on public.inspections
  for select to authenticated
  using (inspector_id = (select auth.uid()));

-- D3: submitted only. Drafts remain private to their owning inspector.
create policy inspections_select_admin_submitted on public.inspections
  for select to authenticated
  using (status = 'submitted' and public.is_admin());

-- `not is_admin()` is required, not redundant: an admin is also an authenticated user,
-- so without it an admin could create inspections of their own and D3's "read-only"
-- would be false. Ownership alone blocks admins from inspector content, but not from
-- creating their own.
create policy inspections_insert_own on public.inspections
  for insert to authenticated
  with check (inspector_id = (select auth.uid()) and not public.is_admin());

-- WITH CHECK matters as much as USING: without it an owner could reassign inspector_id
-- and hand the row to another user.
create policy inspections_update_own on public.inspections
  for update to authenticated
  using      (inspector_id = (select auth.uid()) and not public.is_admin())
  with check (inspector_id = (select auth.uid()) and not public.is_admin());

create policy inspections_delete_own on public.inspections
  for delete to authenticated
  using (inspector_id = (select auth.uid()) and not public.is_admin());

-- No admin write policy of any kind (D3).

-- ---------------------------------------------------------------- inspection_items

create policy inspection_items_select_own on public.inspection_items
  for select to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
  ));

create policy inspection_items_select_admin_submitted on public.inspection_items
  for select to authenticated
  using (
    public.is_admin()
    and exists (
      select 1 from public.inspections i
      where i.id = inspection_items.inspection_id and i.status = 'submitted'
    )
  );

create policy inspection_items_insert_own on public.inspection_items
  for insert to authenticated
  with check (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
  ));

create policy inspection_items_update_own on public.inspection_items
  for update to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
  ));

create policy inspection_items_delete_own on public.inspection_items
  for delete to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = inspection_items.inspection_id
      and i.inspector_id = (select auth.uid())
  ));

-- ---------------------------------------------------------------- item_photos
-- Reaches the owning inspection in one join thanks to the denormalised, FK-guarded
-- inspection_id (D8).

create policy item_photos_select_own on public.item_photos
  for select to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
  ));

create policy item_photos_select_admin_submitted on public.item_photos
  for select to authenticated
  using (
    public.is_admin()
    and exists (
      select 1 from public.inspections i
      where i.id = item_photos.inspection_id and i.status = 'submitted'
    )
  );

create policy item_photos_insert_own on public.item_photos
  for insert to authenticated
  with check (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
  ));

create policy item_photos_update_own on public.item_photos
  for update to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
  ));

create policy item_photos_delete_own on public.item_photos
  for delete to authenticated
  using (exists (
    select 1 from public.inspections i
    where i.id = item_photos.inspection_id
      and i.inspector_id = (select auth.uid())
  ));
