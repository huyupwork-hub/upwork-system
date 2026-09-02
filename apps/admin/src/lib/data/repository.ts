import type { SupabaseClient } from '@supabase/supabase-js';

import { toTsQuery } from './search';
import type {
  FindingSummary,
  GalleryPhoto,
  InspectionDetail,
  InspectionItem,
  ItemPhoto,
  Severity,
  SubmittedInspection,
} from './types';

/**
 * The data boundary. Components receive plain data and never a Supabase client,
 * so a query cannot appear halfway down a component tree and quietly widen what
 * the console reads.
 *
 * Read-only by construction: this interface has no method that writes. The
 * database refuses admin writes regardless (D3, pgTAP 030) — this just means the
 * console has no code path that would attempt one.
 */
export interface AdminRepository {
  listSubmitted(query?: string | null): Promise<SubmittedInspection[]>;
  getSubmitted(id: string): Promise<InspectionDetail | null>;
  listPhotos(): Promise<GalleryPhoto[]>;
}

const INSPECTION_COLUMNS =
  'id, site_name, site_address, client_name, inspection_date, status, ' +
  'submitted_at, created_at, profiles!inspections_inspector_id_fkey(full_name), ' +
  // Nested read, the same shape the profiles join already uses. RLS applies to
  // it exactly as it does to a top-level select: the admin item policy scopes
  // to items whose parent is submitted, so this cannot widen what is visible.
  // Severity and status only — enough to count by, and nothing a reviewer
  // could not already open the inspection and read.
  'inspection_items(severity, status)';

const ITEM_COLUMNS =
  'id, sort_order, title, description, area, severity, status, created_at';

interface InspectionRow {
  id: string;
  site_name: string;
  site_address: string | null;
  client_name: string | null;
  inspection_date: string;
  status: string;
  submitted_at: string | null;
  profiles?: { full_name?: string | null } | { full_name?: string | null }[] | null;
  inspection_items?: { severity: string; status: string }[] | null;
}

function inspectorName(row: InspectionRow): string | null {
  const p = row.profiles;
  if (!p) return null;
  const one = Array.isArray(p) ? p[0] : p;
  return one?.full_name ?? null;
}

/**
 * Counts the nested findings. Absent nesting yields no summary rather than a
 * row of zeroes: "we did not fetch this" and "there are none" are different
 * facts, and a table that prints 0 for both tells the reviewer the wrong one.
 */
function summarise(row: InspectionRow): FindingSummary | undefined {
  const rows = row.inspection_items;
  if (!rows) return undefined;

  const bySeverity: Record<Severity, number> = {
    critical: 0,
    high: 0,
    medium: 0,
    low: 0,
  };
  let open = 0;
  for (const item of rows) {
    if (item.severity in bySeverity) bySeverity[item.severity as Severity] += 1;
    if (item.status === 'open') open += 1;
  }
  return { total: rows.length, open, bySeverity };
}

function toInspection(row: InspectionRow): SubmittedInspection {
  return {
    id: row.id,
    siteName: row.site_name,
    siteAddress: row.site_address,
    clientName: row.client_name,
    inspectionDate: row.inspection_date,
    submittedAt: row.submitted_at,
    status: row.status === 'submitted' ? 'submitted' : 'draft',
    inspectorName: inspectorName(row),
    findings: summarise(row),
  };
}

export class SupabaseAdminRepository implements AdminRepository {
  constructor(private readonly client: SupabaseClient) {}

  /**
   * `.eq('status', 'submitted')` is not the security boundary — the admin SELECT
   * policy already scopes visibility to submitted rows, and an inspector who
   * somehow reached this code would still only ever see their own. It is here so
   * the query states its intent, and so the console cannot drift into listing
   * drafts if the policy were ever relaxed.
   *
   * Ordering matches the mobile client exactly (D22): inspection_date DESC,
   * created_at DESC, id DESC. The last key is what makes it a total order, so
   * two inspections sharing a date do not swap places between page loads.
   */
  async listSubmitted(query?: string | null): Promise<SubmittedInspection[]> {
    let builder = this.client
      .from('inspections')
      .select(INSPECTION_COLUMNS)
      .eq('status', 'submitted');

    const tsQuery = query ? toTsQuery(query) : null;
    if (tsQuery) {
      builder = builder.textSearch('search_tsv', tsQuery, { config: 'simple' });
    }

    const { data, error } = await builder
      .order('inspection_date', { ascending: false })
      .order('created_at', { ascending: false })
      .order('id', { ascending: false });

    if (error) throw new Error(error.message);
    return (data as unknown as InspectionRow[]).map(toInspection);
  }

  async getSubmitted(id: string): Promise<InspectionDetail | null> {
    const { data: row, error } = await this.client
      .from('inspections')
      .select(INSPECTION_COLUMNS)
      .eq('id', id)
      .eq('status', 'submitted')
      .maybeSingle();

    if (error) throw new Error(error.message);
    if (!row) return null;

    const inspection = toInspection(row as unknown as InspectionRow);

    const { data: itemRows, error: itemError } = await this.client
      .from('inspection_items')
      .select(ITEM_COLUMNS)
      .eq('inspection_id', id)
      .order('sort_order', { ascending: true })
      .order('created_at', { ascending: true })
      .order('id', { ascending: true });
    if (itemError) throw new Error(itemError.message);

    const items: InspectionItem[] = (itemRows ?? []).map((r) => {
      const item = r as Record<string, unknown>;
      return {
        id: String(item.id),
        sortOrder: Number(item.sort_order ?? 0),
        title: String(item.title ?? ''),
        description: (item.description as string | null) ?? null,
        area: (item.area as string | null) ?? null,
        severity: item.severity as InspectionItem['severity'],
        status: item.status as InspectionItem['status'],
      };
    });

    const { data: photoRows, error: photoError } = await this.client
      .from('item_photos')
      .select('id, item_id, storage_path, caption, created_at')
      .eq('inspection_id', id)
      .order('created_at', { ascending: true })
      .order('id', { ascending: true });
    if (photoError) throw new Error(photoError.message);

    const photos: ItemPhoto[] = [];
    for (const r of photoRows ?? []) {
      const p = r as Record<string, unknown>;
      // The bucket is private and stays private (D19). A signed URL is minted
      // per request against the reviewer's own session, so storage RLS decides
      // whether it is issued at all.
      const { data: signed } = await this.client.storage
        .from('inspection-photos')
        .createSignedUrl(String(p.storage_path), 60 * 10);

      photos.push({
        id: String(p.id),
        itemId: String(p.item_id),
        caption: (p.caption as string | null) ?? null,
        url: signed?.signedUrl ?? null,
      });
    }

    return { inspection, items, photos };
  }

  /**
   * Every photograph the reviewer is allowed to see, across all submitted
   * inspections.
   *
   * No filter on inspection status here, and none needed: the admin policies on
   * item_photos and on storage.objects both reach through the owning inspection
   * and admit only submitted ones. Adding `.eq` would state an intent the
   * database already enforces, and would read as though it were the boundary.
   *
   * URLs are signed in one batch rather than one request per photo. A gallery
   * of forty photographs would otherwise be forty round trips before the page
   * could render.
   */
  async listPhotos(): Promise<GalleryPhoto[]> {
    const { data, error } = await this.client
      .from('item_photos')
      // The site name is reached *through* the finding, not directly.
      // item_photos has exactly one foreign key — a composite
      // (item_id, inspection_id) -> inspection_items — and none to inspections
      // at all, so asking PostgREST to embed inspections here fails with "could
      // not find a relationship". The item owns that edge, so the embed nests.
      .select(
        'id, caption, storage_path, inspection_id, created_at, ' +
          'inspection_items!item_photos_item_fk(' +
          'title, severity, inspections(site_name))',
      )
      .order('created_at', { ascending: false })
      .order('id', { ascending: false });
    if (error) throw new Error(error.message);

    const rows = (data ?? []) as unknown as GalleryRow[];
    if (rows.length === 0) return [];

    const paths = rows.map((r) => r.storage_path);
    const { data: signed } = await this.client.storage
      .from('inspection-photos')
      .createSignedUrls(paths, 60 * 10);

    // Matched by path rather than by index: a batch that drops or reorders an
    // entry would otherwise attach one photograph's URL to another's caption,
    // which is a worse failure than a missing image.
    const urlByPath = new Map<string, string>();
    for (const entry of signed ?? []) {
      if (entry.path && entry.signedUrl) urlByPath.set(entry.path, entry.signedUrl);
    }

    return rows.map((r) => {
      const item = one(r.inspection_items);
      const inspection = one(item?.inspections);
      return {
        id: String(r.id),
        caption: r.caption ?? null,
        url: urlByPath.get(r.storage_path) ?? null,
        inspectionId: String(r.inspection_id),
        inspectionName: inspection?.site_name ?? 'Unknown inspection',
        itemTitle: item?.title ?? 'Untitled finding',
        severity: (item?.severity as Severity) ?? 'low',
      };
    });
  }
}

interface GalleryItem {
  title?: string | null;
  severity?: string | null;
  inspections?:
    | { site_name?: string | null }
    | { site_name?: string | null }[]
    | null;
}

interface GalleryRow {
  id: string;
  caption: string | null;
  storage_path: string;
  inspection_id: string;
  inspection_items?: GalleryItem | GalleryItem[] | null;
}

/** PostgREST returns a nested to-one either as an object or a one-element array. */
function one<T>(value: T | T[] | null | undefined): T | undefined {
  if (!value) return undefined;
  return Array.isArray(value) ? value[0] : value;
}
