import { notFound } from 'next/navigation';

import { AppShell } from '@/components/AppShell';
import { InspectionDetailView } from '@/components/InspectionDetailView';
import { currentDisplayName, requireAdmin } from '@/lib/auth';
import { SupabaseAdminRepository } from '@/lib/data/repository';
import { createClient } from '@/lib/supabase/server';

export const dynamic = 'force-dynamic';

/**
 * A draft reaches this page as a 404, not as a redirect or an error: the
 * repository asks for a submitted row by id and RLS would withhold a draft
 * anyway, so "no such reviewable inspection" is the truthful answer and it
 * leaks nothing about whether the id exists.
 */
export default async function InspectionDetailPage({
  params,
}: {
  params: { id: string };
}) {
  await requireAdmin();

  const repo = new SupabaseAdminRepository(createClient());
  const detail = await repo.getSubmitted(params.id);
  if (!detail) notFound();

  const who = await currentDisplayName();

  return (
    <AppShell active="inspections" who={who}>
      <InspectionDetailView detail={detail} />
    </AppShell>
  );
}
