-- One stored rendering of the report per submitted inspection, write-once (D21 amended, D31).
--
-- Layout:  inspection-reports/{inspector_id}/{inspection_id}/report.pdf
--
-- The same two leading segments as inspection-photos, so ownership is again a prefix
-- comparison and the read policies are the shape 20260831000400 already uses. The INSERT
-- policy pins the WHOLE name rather than a prefix: exactly one name per inspection is
-- writable at all, and the unique index on storage.objects (bucket_id, name) turns a second
-- write into a 23505, not a second object. Through the Storage API the same refusal arrives
-- as HTTP 400 wrapping statusCode 409 / error "Duplicate", because the API looks for the
-- object before it writes (hosted smoke 22b is the evidence for that half).
--
-- Write-once by absence: there is no UPDATE policy and no DELETE policy for this bucket, for
-- any role. The Storage API's x-upsert path needs UPDATE and is refused; remove() matches
-- zero rows and returns []. No admin write policy (D3, D23). No anon policy.
--
-- The write side is the mirror image of D17: photographs are written only while the
-- inspection is a draft; the report is written only once it is submitted. A draft can have
-- no stored report (D21 eligibility, now enforced here as well as in the loader).
--
-- Deliberately no `and not public.is_admin()` on the write policy. An admin owns no
-- inspection (inspections_insert_own refuses one), so the subquery is empty for an admin and
-- the conjunct would be dead; and 080 asserts, literally, that no non-SELECT storage policy
-- mentions is_admin at all -- the same trap 010 documents for public. The one reachable
-- case, an inspector promoted to admin after submitting work, could publish the report of
-- their OWN old inspection and nothing else; recorded in D31.
--
-- No table. storage.objects is the index: the object's existence at the policy-pinned name
-- is the fact, and there is nothing a second row could say that the name does not.

-- Private (D19): served through signed URLs only. PDF only, by Content-Type header. 50 MB,
-- the project's own upload ceiling: a report embeds its photographs, and D20 caps each of
-- those at 10 MB. The client mirrors the cap as ReportLimits.maxBytes and
-- constraint_parity_test.dart reads the number from this file -- keep the VALUES on one line.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('inspection-reports', 'inspection-reports', false, 52428800, array['application/pdf'])
on conflict (id) do nothing;

-- ---------------------------------------------------------------- owner

create policy "inspection reports: owner read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'inspection-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Exactly one name, only for the owner, only while submitted. The subquery runs under the
-- caller's own RLS on inspections and yields at most the caller's own submitted rows, so a
-- forged owner segment, another inspector's id, a draft, a sibling name and a deeper path
-- all fail the same way: the name is not in the set, and WITH CHECK raises 42501.
create policy "inspection reports: owner publish once" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'inspection-reports'
    and name in (
      select i.inspector_id::text || '/' || i.id::text || '/report.pdf'
      from public.inspections i
      where i.inspector_id = (select auth.uid())
        and i.status = 'submitted'
    )
  );

-- ---------------------------------------------------------------- admin, submitted only
--
-- Pinned to the one name a submitted inspection may carry, not to a prefix: an object a
-- privileged actor planted beside it, or under a draft, is invisible by construction. The
-- subquery runs under the admin's own RLS on inspections (submitted only) and the name is
-- compared as text, for the reason 20260831000400 gives: a malformed name must deny, not
-- raise inside the policy. is_admin() stays load-bearing -- without it the subquery would
-- admit an inspector's own submitted reports through this policy as well, harmlessly but
-- against the policy's name.
create policy "inspection reports: admin read submitted" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'inspection-reports'
    and public.is_admin()
    and name in (
      select i.inspector_id::text || '/' || i.id::text || '/report.pdf'
      from public.inspections i
      where i.status = 'submitted'
    )
  );

-- No UPDATE policy. No DELETE policy. No admin write policy (D3). No anon policy.
--
-- No `comment on policy`: COMMENT needs ownership of storage.objects, which the migration
-- role does not hold (CI run 33972594943 failed the apply with 42501 "must be owner of
-- relation objects"), whereas CREATE POLICY is granted to it. The policy's intent lives in
-- the comments above and in D31 instead.
