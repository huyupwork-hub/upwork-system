import { AppShell } from '@/components/AppShell';
import { InspectionsTable } from '@/components/InspectionsTable';
import { currentDisplayName, requireAdmin } from '@/lib/auth';
import { SupabaseAdminRepository } from '@/lib/data/repository';
import { createClient } from '@/lib/supabase/server';
import type { SubmittedInspection } from '@/lib/data/types';

export const dynamic = 'force-dynamic';

/**
 * Search, filter and sort all live in the URL. That makes a result set
 * linkable and the back button meaningful, and it sidesteps the stale-response
 * problem the mobile client needs a generation token for — the browser only
 * ever renders the navigation it settled on. No client component is involved
 * because none is needed.
 */

type Triage = 'all' | 'critical' | 'open' | 'resolved';
type Sort = 'date' | 'property';

/**
 * The reference design filters this table by inspection status and sorts by it
 * too. Neither can work here: the admin SELECT policy scopes visibility to
 * submitted rows and the query says so again, so every row on this page has the
 * same status. A "Draft" chip would match nothing on every click and a
 * "Sort: Status" would never reorder anything.
 *
 * The toolbar keeps the design's shape — search, a row of chips, a sort control
 * — and spends it on the question a reviewer actually has when opening a queue:
 * which of these needs me first. All three filters are computed from findings
 * already fetched for the table.
 */
const TRIAGE: { key: Triage; label: string; match: (i: SubmittedInspection) => boolean }[] = [
  { key: 'all', label: 'All', match: () => true },
  {
    key: 'critical',
    label: 'Has critical',
    match: (i) => (i.findings?.bySeverity.critical ?? 0) > 0,
  },
  { key: 'open', label: 'Open findings', match: (i) => (i.findings?.open ?? 0) > 0 },
  {
    key: 'resolved',
    label: 'All resolved',
    match: (i) => !!i.findings && i.findings.total > 0 && i.findings.open === 0,
  },
];

export default async function InspectionsPage({
  searchParams,
}: {
  searchParams: { q?: string; filter?: string; sort?: string };
}) {
  await requireAdmin();

  const query = (searchParams?.q ?? '').trim();
  const triage = (TRIAGE.find((t) => t.key === searchParams?.filter)?.key ??
    'all') as Triage;
  const sort: Sort = searchParams?.sort === 'property' ? 'property' : 'date';

  const repo = new SupabaseAdminRepository(createClient());
  const all = await repo.listSubmitted(query || null);
  const who = await currentDisplayName();

  const matcher = TRIAGE.find((t) => t.key === triage)!.match;
  const filtered = all.filter(matcher);

  // Date order is the repository's, which is a total order (D22) and therefore
  // stable across loads. Property order is a re-sort of rows already in hand —
  // it does not issue a second query, so it cannot disagree with the first.
  const shown =
    sort === 'property'
      ? [...filtered].sort((a, b) => a.siteName.localeCompare(b.siteName))
      : filtered;

  const href = (next: { filter?: Triage; sort?: Sort }) => {
    const p = new URLSearchParams();
    if (query) p.set('q', query);
    const f = next.filter ?? triage;
    const s = next.sort ?? sort;
    if (f !== 'all') p.set('filter', f);
    if (s !== 'date') p.set('sort', s);
    const qs = p.toString();
    return qs ? `/inspections?${qs}` : '/inspections';
  };

  return (
    <AppShell active="inspections" who={who}>
      <div className="page-head">
        <h1>Inspections</h1>
        <p className="page-sub">
          {shown.length} of {all.length} inspection{all.length === 1 ? '' : 's'}
        </p>
      </div>

      <div className="toolbar">
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

        <div className="chips">
          {TRIAGE.map((t) => (
            <a
              key={t.key}
              className={t.key === triage ? 'chip active' : 'chip'}
              href={href({ filter: t.key })}
              aria-current={t.key === triage ? 'true' : undefined}
            >
              {t.label}
            </a>
          ))}
        </div>

        <div className="sortbar">
          <span className="label">Sort</span>
          <a className={sort === 'date' ? 'chip active' : 'chip'} href={href({ sort: 'date' })}>
            Date
          </a>
          <a
            className={sort === 'property' ? 'chip active' : 'chip'}
            href={href({ sort: 'property' })}
          >
            Property
          </a>
        </div>
      </div>

      <div className="page-body">
        <InspectionsTable inspections={shown} query={query} />
      </div>
    </AppShell>
  );
}
