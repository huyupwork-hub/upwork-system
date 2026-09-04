-- Function hardening. Every change here narrows what already exists: no new behaviour,
-- no signature change, no policy change, no trigger recreated.
--
-- 1. EXECUTE on the three trigger functions was never revoked. PostgreSQL grants EXECUTE
--    to PUBLIC on every function it creates, so anon and authenticated could call all
--    three directly. That was not exploitable as written — calling a trigger function
--    outside a trigger fails with 0A000 before its body runs — but handle_new_user() is
--    SECURITY DEFINER, and a default grant on a definer function is a standing invitation
--    that costs nothing to withdraw. The triggers keep firing: PostgreSQL checks EXECUTE
--    when a trigger is created, not each time it fires.
--
-- 2. set_updated_at() and enforce_submission_transition() ran with a mutable search_path.
--    Neither is SECURITY DEFINER, so neither was a privilege-escalation route, but both
--    run on every authenticated write and both are flagged by Supabase's own linter
--    (function_search_path_mutable). Pinning costs nothing and removes the question.
--
--    now() is schema-qualified rather than relied upon: pg_catalog is searched implicitly
--    even under an empty search_path, but writing pg_catalog.now() means nobody reading
--    this has to know that.
--
-- 3. is_admin() was reviewed and is deliberately NOT changed. It is already SECURITY
--    DEFINER with search_path pinned, already revoked from public and anon, and already
--    granted only to authenticated. It takes no argument and reports on (select auth.uid())
--    alone, so it cannot be asked about another user, and it returns a boolean rather than
--    any row it read. Recorded here because "reviewed, correct, unchanged" is a result and
--    the next reader should not have to re-derive it.

-- ---------------------------------------------------------------- 1. execute grants

revoke all on function public.handle_new_user()             from public, anon, authenticated;
revoke all on function public.set_updated_at()              from public, anon, authenticated;
revoke all on function public.enforce_submission_transition() from public, anon, authenticated;

-- ---------------------------------------------------------------- 2. pinned search_path
-- CREATE OR REPLACE keeps the existing triggers bound to these functions; the bodies are
-- unchanged apart from qualifying now().

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = pg_catalog.now();
  return new;
end;
$$;

create or replace function public.enforce_submission_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'submitted' and new.status = 'draft' then
    raise exception 'an inspection cannot be returned to draft once submitted'
      using errcode = 'check_violation';
  end if;

  if old.status = 'draft' and new.status = 'submitted' and new.submitted_at is null then
    new.submitted_at = pg_catalog.now();
  end if;

  return new;
end;
$$;

-- CREATE OR REPLACE re-grants EXECUTE to PUBLIC on the replaced functions, so the revoke
-- has to follow the replacement, not precede it. Repeated deliberately rather than
-- reordered: the revoke above documents the intent for handle_new_user(), which is not
-- replaced here, and this one is what actually holds for the two that are.

revoke all on function public.set_updated_at()                from public, anon, authenticated;
revoke all on function public.enforce_submission_transition() from public, anon, authenticated;
