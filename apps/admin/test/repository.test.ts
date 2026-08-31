import type { SupabaseClient } from '@supabase/supabase-js';
import { describe, expect, it } from 'vitest';

import { SupabaseAdminRepository } from '@/lib/data/repository';

/**
 * A recording fake stands in for PostgREST so the query the console *sends* can
 * be asserted. It deliberately does not re-implement RLS: the database is the
 * authority on what comes back, proven in pgTAP 020/030, and a fake that
 * pretended to enforce ownership would make these tests agree with themselves
 * rather than with Postgres.
 */
interface Recorded {
  table: string;
  filters: [string, string, unknown][];
  orders: [string, boolean][];
  textSearch: { column: string; query: string; config?: string } | null;
}

function fakeClient(rows: Record<string, unknown[]>) {
  const calls: Recorded[] = [];

  const builder = (table: string) => {
    const rec: Recorded = { table, filters: [], orders: [], textSearch: null };
    calls.push(rec);

    const chain: Record<string, unknown> = {
      select: () => chain,
      eq: (col: string, val: unknown) => {
        rec.filters.push(['eq', col, val]);
        return chain;
      },
      textSearch: (
        column: string,
        query: string,
        opts?: { config?: string },
      ) => {
        rec.textSearch = { column, query, config: opts?.config };
        return chain;
      },
      order: (col: string, opts?: { ascending?: boolean }) => {
        rec.orders.push([col, opts?.ascending !== false]);
        return chain;
      },
      maybeSingle: async () => {
        const table_rows = rows[table] ?? [];
        // Honour the eq filters the caller applied, so a draft id genuinely
        // finds nothing when the repository asks for a submitted row.
        const match = table_rows.find((r) =>
          rec.filters.every(
            ([, col, val]) => (r as Record<string, unknown>)[col] === val,
          ),
        );
        return { data: match ?? null, error: null };
      },
      then: (
        resolve: (v: { data: unknown[]; error: null }) => unknown,
      ) => {
        const table_rows = (rows[table] ?? []).filter((r) =>
          rec.filters.every(
            ([, col, val]) => (r as Record<string, unknown>)[col] === val,
          ),
        );
        return Promise.resolve(resolve({ data: table_rows, error: null }));
      },
    };
    return chain;
  };

  const client = {
    from: (table: string) => builder(table),
    storage: {
      from: () => ({
        createSignedUrl: async (path: string) => ({
          data: { signedUrl: `signed:${path}` },
          error: null,
        }),
      }),
    },
  } as unknown as SupabaseClient;

  return { client, calls };
}

const submittedRow = {
  id: 'a2',
  site_name: 'Northgate Retail Park',
  site_address: '4 Northgate Way',
  client_name: 'Cavendish Estates',
  inspection_date: '2026-08-22',
  status: 'submitted',
  submitted_at: '2026-08-22T14:00:00+00:00',
  profiles: { full_name: 'Inspector Alpha' },
};

const draftRow = { ...submittedRow, id: 'a1', status: 'draft', submitted_at: null };

describe('listSubmitted', () => {
  it('asks only for submitted inspections', async () => {
    const { client, calls } = fakeClient({ inspections: [submittedRow, draftRow] });
    const rows = await new SupabaseAdminRepository(client).listSubmitted();

    expect(calls[0].filters).toContainEqual(['eq', 'status', 'submitted']);
    expect(rows.map((r) => r.id)).toEqual(['a2']);
    expect(rows.every((r) => r.status === 'submitted')).toBe(true);
  });

  it('reuses the accepted deterministic ordering', async () => {
    const { client, calls } = fakeClient({ inspections: [submittedRow] });
    await new SupabaseAdminRepository(client).listSubmitted();

    // inspection_date DESC, created_at DESC, id DESC — the same total order the
    // mobile client uses (D22). The final key is what stops two inspections on
    // one date swapping places between page loads.
    expect(calls[0].orders).toEqual([
      ['inspection_date', false],
      ['created_at', false],
      ['id', false],
    ]);
  });

  it('searches server-side against the existing tsvector', async () => {
    const { client, calls } = fakeClient({ inspections: [submittedRow] });
    await new SupabaseAdminRepository(client).listSubmitted('North Gate');

    expect(calls[0].textSearch).toEqual({
      column: 'search_tsv',
      query: 'north:* & gate:*',
      config: 'simple',
    });
    // Still scoped to submitted: search must not become a way to widen the set.
    expect(calls[0].filters).toContainEqual(['eq', 'status', 'submitted']);
  });

  it('treats a blank query as no query rather than an empty search', async () => {
    const { client, calls } = fakeClient({ inspections: [submittedRow] });
    await new SupabaseAdminRepository(client).listSubmitted('   ');
    expect(calls[0].textSearch).toBeNull();
  });

  it('carries the inspector name through from the joined profile', async () => {
    const { client } = fakeClient({ inspections: [submittedRow] });
    const rows = await new SupabaseAdminRepository(client).listSubmitted();
    expect(rows[0].inspectorName).toBe('Inspector Alpha');
  });
});

describe('getSubmitted', () => {
  it('returns nothing for a draft id', async () => {
    const { client } = fakeClient({ inspections: [draftRow] });
    const detail = await new SupabaseAdminRepository(client).getSubmitted('a1');
    expect(detail).toBeNull();
  });

  it('loads a submitted inspection with items and signed photos', async () => {
    const { client, calls } = fakeClient({
      inspections: [submittedRow],
      inspection_items: [
        {
          id: 'i1',
          inspection_id: 'a2',
          sort_order: 0,
          title: 'Exposed wiring',
          description: 'Cover missing.',
          area: 'Plant room',
          severity: 'critical',
          status: 'open',
        },
      ],
      item_photos: [
        {
          id: 'p1',
          item_id: 'i1',
          inspection_id: 'a2',
          storage_path: 'u/a2/i1/p1.jpg',
          caption: 'Detail',
        },
      ],
    });

    const detail = await new SupabaseAdminRepository(client).getSubmitted('a2');

    expect(detail?.inspection.siteName).toBe('Northgate Retail Park');
    expect(detail?.items.map((i) => i.title)).toEqual(['Exposed wiring']);
    expect(detail?.photos[0].url).toBe('signed:u/a2/i1/p1.jpg');

    // The detail read is pinned to submitted too, so a draft cannot be opened
    // by guessing its id.
    expect(calls[0].filters).toContainEqual(['eq', 'status', 'submitted']);
  });
});
