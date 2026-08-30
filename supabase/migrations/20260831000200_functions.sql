-- Functions and triggers. All SECURITY DEFINER functions pin an empty search_path.

-- Role lookup. SECURITY DEFINER because a policy on profiles that itself queries
-- profiles would recurse; a definer function bypasses RLS and breaks the cycle (D9).
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- A profile must always exist for an authenticated user.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
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

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- updated_at is maintained server-side; clients cannot forge it.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger inspections_set_updated_at
before update on public.inspections
for each row execute function public.set_updated_at();

create trigger inspection_items_set_updated_at
before update on public.inspection_items
for each row execute function public.set_updated_at();

-- Submission is one-way (D10).
--
-- Admin visibility is gated on status = 'submitted'. If an inspector could return a
-- submitted inspection to draft, they could retract it from review at will, which would
-- make the review gate unenforceable. Fails closed.
-- Also stamps submitted_at so the column cannot disagree with status.
create or replace function public.enforce_submission_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'submitted' and new.status = 'draft' then
    raise exception 'an inspection cannot be returned to draft once submitted'
      using errcode = 'check_violation';
  end if;

  if old.status = 'draft' and new.status = 'submitted' and new.submitted_at is null then
    new.submitted_at = now();
  end if;

  return new;
end;
$$;

create trigger inspections_enforce_submission
before update of status on public.inspections
for each row execute function public.enforce_submission_transition();
