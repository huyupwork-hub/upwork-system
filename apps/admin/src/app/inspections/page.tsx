import { signOut } from '@/app/actions';
import { InspectionsTable } from '@/components/InspectionsTable';
import { currentDisplayName, requireAdmin } from '@/lib/auth';
import { SupabaseAdminRepository } from '@/lib/data/repository';
import { createClient } from '@/lib/supabase/server';

export const dynamic = 'force-dynamic';

/**
 * Search is a plain GET form, so the query lives in the URL. That makes a
 * result set linkable and the back button meaningful, and it sidesteps the
 * stale-response problem the mobile client needs a generation token for — the
 * browser only ever renders the navigation it settled on. No client state
 * library is involved because none is needed.
 */
export default async function InspectionsPage({
  searchParams,
}: {
  searchParams: { q?: string };
}) {
  await requireAdmin();

  const query = (searchParams?.q ?? '').trim();
  const repo = new SupabaseAdminRepository(createClient());
  const inspections = await repo.listSubmitted(query || null);
  const who = await currentDisplayName();

  return (
    <main className="shell">
      <div className="topbar">
        <h1>Submitted Inspections</h1>
        <span className="who">
          {who ? `${who} · ` : ''}
          <form action={signOut} style={{ display: 'inline' }}>
            <button
              type="submit"
              style={{
                background: 'none',
                border: 'none',
                padding: 0,
                font: 'inherit',
                color: 'var(--blue)',
                cursor: 'pointer',
              }}
            >
              Sign out
            </button>
          </form>
        </span>
      </div>

      <form className="search" method="get" action="/inspections">
        <input
          type="search"
          name="q"
          defaultValue={query}
          placeholder="Search site, address or client"
          aria-label="Search submitted inspections"
        />
        <button className="go" type="submit">
          Search
        </button>
      </form>

      <InspectionsTable inspections={inspections} query={query} />
    </main>
  );
}
