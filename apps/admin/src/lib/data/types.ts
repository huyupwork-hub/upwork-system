/**
 * Types mirror the accepted schema (docs/DATA_MODEL.md), not the UI. The enums
 * are the database's: severity is low|medium|high|critical and item status is
 * open|resolved (D14 — the Figma variants were rejected in favour of these).
 */

export type InspectionStatus = 'draft' | 'submitted';
export type Severity = 'low' | 'medium' | 'high' | 'critical';
export type ItemStatus = 'open' | 'resolved';

export const SEVERITY_ORDER: readonly Severity[] = [
  'critical',
  'high',
  'medium',
  'low',
];

export interface SubmittedInspection {
  id: string;
  siteName: string;
  siteAddress: string | null;
  clientName: string | null;
  inspectionDate: string;
  submittedAt: string | null;
  status: InspectionStatus;
  inspectorName: string | null;
}

export interface InspectionItem {
  id: string;
  sortOrder: number;
  title: string;
  description: string | null;
  area: string | null;
  severity: Severity;
  status: ItemStatus;
}

export interface ItemPhoto {
  id: string;
  itemId: string;
  caption: string | null;
  /** Time-limited signed URL. The bucket is private and stays private (D19). */
  url: string | null;
}

export interface InspectionDetail {
  inspection: SubmittedInspection;
  items: InspectionItem[];
  photos: ItemPhoto[];
}
