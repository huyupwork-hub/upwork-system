import type { SupabaseClient } from '@supabase/supabase-js';
import { describe, expect, it } from 'vitest';

import {
  REPORT_BUCKET,
  REPORT_FOLDER_LIST_LIMIT,
  SupabaseAdminRepository,
  reportStoragePath,
} from '@/lib/data/repository';

/**
 * A recording fake stands in for PostgREST so the query the console *sends* can
 * be asserted. It deliberately does not re-implement RLS: the database is the
 * authority on what comes back, proven in pgTAP 020/030, and a fake that
 * pretended to enforce ownership would make these tests agree with themselves
 * rather than with Postgres.
 *
 * The storage half records the same way: which bucket was asked, for which
 * prefix, and what was signed under what name. Whether a listing or a signed
 * URL is *issued* at all is the storage policies' decision (pgTAP 080/110);
 * here a listing is whatever the case configures, and an unconfigured prefix
 * lists nothing — the shape Storage answers with for a folder that holds no
 * object, which is "absent", not an error.
 */
interface Recorded {
  table: string;
  select: string | null;
  filters: [string, string, unknown][];
  orders: [string, boolean][];
  textSearch: { column: string; query: string; config?: string } | null;
}

interface ListCall {
  bucket: string;
  path: string;
  limit: number | undefined;
}

interface SignCall {
  bucket: string;
  path: string;
  expiresIn: number;
  options: { download?: string | boolean } | undefined;
}

/** One folder's answer: the names in it, a storage-js error, or a rejection. */
type Listing = { entries: string[] } | { error: string } | { throws: string };

interface StorageFixture {
  /** Keyed by `<bucket>/<prefix>` exactly as the repository asks for them. */
  listings?: Record<string, Listing>;
  /** Object paths whose signing fails, the way a stale or withheld object does. */
  unsignable?: string[];
}

function fakeClient(
  rows: Record<string, unknown[]>,
  storage: StorageFixture = {},
) {
  const calls: Recorded[] = [];
  const lists: ListCall[] = [];
  const signs: SignCall[] = [];

  const builder = (table: string) => {
    const rec: Recorded = {
      table,
      select: null,
      filters: [],
      orders: [],
      textSearch: null,
    };
    calls.push(rec);

    const chain: Record<string, unknown> = {
      select: (columns: string) => {
        rec.select = columns;
        return chain;
      },
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
      from: (bucket: string) => ({
        list: async (path: string, options?: { limit?: number }) => {
          lists.push({ bucket, path, limit: options?.limit });
          const listing = storage.listings?.[`${bucket}/${path}`] ?? {
            entries: [],
          };
          if ('throws' in listing) throw new Error(listing.throws);
          if ('error' in listing) {
            return { data: null, error: { message: listing.error } };
          }
          return {
            data: listing.entries.map((name) => ({ name })),
            error: null,
          };
        },
        createSignedUrl: async (
          path: string,
          expiresIn: number,
          options?: { download?: string | boolean },
        ) => {
          signs.push({ bucket, path, expiresIn, options });
          if (storage.unsignable?.includes(path)) {
            return { data: null, error: { message: 'Object not found' } };
          }
          // The bucket is part of the answer so a test can tell a report
          // signed in the wrong bucket from one signed in the right one.
          return {
            data: { signedUrl: `signed:${bucket}:${path}` },
            error: null,
          };
        },
      }),
    },
  } as unknown as SupabaseClient;

  return { client, calls, lists, signs };
}

// `inspector_id` is the auth uid that heads every storage name the inspection
// owns; `u` here matches the photo path fixture below. The id is deliberately
// the short `a2` the other cases already key on, so the "first eight hex" of
// the filename is the whole of it; report_filename.test.ts pins the eight-hex
// rule on the Dart fixtures.
const submittedRow = {
  id: 'a2',
  inspector_id: 'u',
  site_name: 'Northgate Retail Park',
  site_address: '4 Northgate Way',
  client_name: 'Cavendish Estates',
  inspection_date: '2026-08-22',
  status: 'submitted',
  submitted_at: '2026-08-22T14:00:00+00:00',
  profiles: { full_name: 'Inspector Alpha' },
};

const draftRow = { ...submittedRow, id: 'a1', status: 'draft', submitted_at: null };

const REPORT_FILENAME = 'fieldproof-northgate-retail-park-20260822-a2.pdf';

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

  it('reads inspector_id, the folder the stored report lives under', async () => {
    const { client, calls } = fakeClient({ inspections: [submittedRow] });
    const rows = await new SupabaseAdminRepository(client).listSubmitted();

    // The column is the only way the console can name `<uid>/<id>/report.pdf`
    // (D31); the profile join still carries the name that is shown.
    expect(calls[0].select).toContain('inspector_id');
    expect(rows[0].inspectorId).toBe('u');
  });

  it('lists each distinct inspector folder in the reports bucket once', async () => {
    const second = { ...submittedRow, id: 'a3', site_name: 'Harbour View' };
    const other = { ...submittedRow, id: 'b1', inspector_id: 'v' };
    const { client, lists } = fakeClient(
      { inspections: [submittedRow, second, other] },
      { listings: { 'inspection-reports/u': { entries: ['a2'] } } },
    );
    const rows = await new SupabaseAdminRepository(client).listSubmitted();

    // Two of u's rows, one listing of u's folder: the folder is a fact about
    // the objects beneath it, not about any one row.
    expect(lists.map((l) => [l.bucket, l.path])).toEqual([
      ['inspection-reports', 'u'],
      ['inspection-reports', 'v'],
    ]);
    expect(lists.every((l) => l.limit === REPORT_FOLDER_LIST_LIMIT)).toBe(true);
    expect(rows.map((r) => [r.id, r.hasReport])).toEqual([
      ['a2', true],
      ['a3', false],
      ['b1', false],
    ]);
  });

  it('leaves hasReport undefined when a folder cannot be listed', async () => {
    const other = { ...submittedRow, id: 'b1', inspector_id: 'v' };
    const third = { ...submittedRow, id: 'c1', inspector_id: 'w' };
    const { client } = fakeClient(
      { inspections: [submittedRow, other, third] },
      {
        listings: {
          'inspection-reports/u': { error: 'storage unavailable' },
          'inspection-reports/v': { throws: 'network' },
        },
      },
    );
    const rows = await new SupabaseAdminRepository(client).listSubmitted();

    // "Not yet" is a claim about the inspection; a listing that failed is a
    // fact about storage. The queue prints a dash for the former, and the
    // failure of one inspector's folder does not touch another's rows.
    expect(rows.map((r) => [r.id, r.hasReport])).toEqual([
      ['a2', undefined],
      ['b1', undefined],
      ['c1', false],
    ]);
  });

  it('cannot conclude "Not yet" from a listing that filled its limit', async () => {
    const second = { ...submittedRow, id: 'a3' };
    const full = Array.from({ length: REPORT_FOLDER_LIST_LIMIT }, (_, i) =>
      i === 0 ? 'a2' : `x${i}`,
    );
    const { client } = fakeClient(
      { inspections: [submittedRow, second] },
      { listings: { 'inspection-reports/u': { entries: full } } },
    );
    const rows = await new SupabaseAdminRepository(client).listSubmitted();

    // What is in the page is known; what fell off the end is not.
    expect(rows.map((r) => [r.id, r.hasReport])).toEqual([
      ['a2', true],
      ['a3', undefined],
    ]);
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
    expect(detail?.photos[0].url).toBe('signed:inspection-photos:u/a2/i1/p1.jpg');

    // The detail read is pinned to submitted too, so a draft cannot be opened
    // by guessing its id.
    expect(calls[0].filters).toContainEqual(['eq', 'status', 'submitted']);
    expect(calls[0].select).toContain('inspector_id');
  });

  it('signs the stored report under the product filename when the folder holds it', async () => {
    const { client, lists, signs } = fakeClient(
      { inspections: [submittedRow] },
      { listings: { 'inspection-reports/u/a2': { entries: ['report.pdf'] } } },
    );

    const detail = await new SupabaseAdminRepository(client).getSubmitted('a2');

    expect(lists).toContainEqual({
      bucket: 'inspection-reports',
      path: 'u/a2',
      limit: undefined,
    });
    // Ten minutes, the pinned name, and `download` set to the name the phone's
    // share sheet offers: the browser saves the same document under the same
    // name on either side, and Storage answers as an attachment rather than
    // rendering an inspector's document inline on its own origin.
    expect(signs.filter((s) => s.bucket === REPORT_BUCKET)).toEqual([
      {
        bucket: 'inspection-reports',
        path: 'u/a2/report.pdf',
        expiresIn: 600,
        options: { download: REPORT_FILENAME },
      },
    ]);
    expect(detail?.report).toEqual({
      present: true,
      url: 'signed:inspection-reports:u/a2/report.pdf',
      filename: REPORT_FILENAME,
    });
  });

  it('reports absence, and signs nothing, when the folder is empty', async () => {
    const { client, signs } = fakeClient({ inspections: [submittedRow] });

    const detail = await new SupabaseAdminRepository(client).getSubmitted('a2');

    // An unconfigured prefix lists nothing, which is how Storage answers for a
    // folder without objects. No signing attempt: a URL to nothing would be a
    // link the reviewer clicks into a 404.
    expect(detail?.report).toEqual({
      present: false,
      url: null,
      filename: REPORT_FILENAME,
    });
    expect(signs.filter((s) => s.bucket === REPORT_BUCKET)).toEqual([]);
  });

  it('counts only report.pdf as the report', async () => {
    const { client, signs } = fakeClient(
      { inspections: [submittedRow] },
      { listings: { 'inspection-reports/u/a2': { entries: ['notes.pdf'] } } },
    );

    const detail = await new SupabaseAdminRepository(client).getSubmitted('a2');

    // The write policy admits no other name, so this cannot happen through a
    // client; the check is still by exact name so a listing is never read as
    // "something is there, sign the pinned path".
    expect(detail?.report.present).toBe(false);
    expect(signs.filter((s) => s.bucket === REPORT_BUCKET)).toEqual([]);
  });

  it('keeps present true when the object is listed but cannot be signed', async () => {
    const { client } = fakeClient(
      { inspections: [submittedRow] },
      {
        listings: { 'inspection-reports/u/a2': { entries: ['report.pdf'] } },
        unsignable: ['u/a2/report.pdf'],
      },
    );

    const detail = await new SupabaseAdminRepository(client).getSubmitted('a2');

    // "Exists but could not be loaded" and "not uploaded" are different facts,
    // and the view says which (the photo-missing rule applied to the document).
    expect(detail?.report).toEqual({
      present: true,
      url: null,
      filename: REPORT_FILENAME,
    });
  });

  it('fails the read rather than claiming absence when the folder cannot be listed', async () => {
    const { client } = fakeClient(
      { inspections: [submittedRow] },
      { listings: { 'inspection-reports/u/a2': { error: 'storage unavailable' } } },
    );

    // Neither present nor absent is known, and `report` has no third state on
    // purpose: the page fails the way it fails when items or photos cannot be
    // read, instead of telling the reviewer nothing was uploaded (D28).
    await expect(
      new SupabaseAdminRepository(client).getSubmitted('a2'),
    ).rejects.toThrow('storage unavailable');
  });
});

describe('reportStoragePath', () => {
  it("pins the one name the bucket's write policy admits", () => {
    // The literal in 20260905001100_inspection_reports.sql and
    // reportStoragePath() in report_store.dart; pgTAP 110 and
    // report_store_test.dart pin those two sides.
    expect(REPORT_BUCKET).toBe('inspection-reports');
    expect(reportStoragePath('u', 'a2')).toBe('u/a2/report.pdf');
  });
});
