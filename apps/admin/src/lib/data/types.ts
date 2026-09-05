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

/** Counts derived from the inspection's own findings. Optional because a row
 * may be constructed without them — the table then shows a dash rather than a
 * zero, which would be a claim. */
export interface FindingSummary {
  total: number;
  open: number;
  bySeverity: Record<Severity, number>;
}

export interface SubmittedInspection {
  id: string;
  /** The inspector's auth uid: the first segment of every storage name the
   * inspection owns, which is how the console finds its stored report (D31).
   * Never shown — the profile join carries the name. */
  inspectorId: string;
  siteName: string;
  siteAddress: string | null;
  clientName: string | null;
  inspectionDate: string;
  submittedAt: string | null;
  status: InspectionStatus;
  inspectorName: string | null;
  /** Derived, not stored. See FindingSummary. */
  findings?: FindingSummary;
  /** Whether an object exists at the report's pinned name. Optional for the
   * FindingSummary reason: undefined means the folder was not, or could not
   * be, listed, and the queue shows a dash rather than "Not yet", which would
   * be a claim. */
  hasReport?: boolean;
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

/** The PDF the inspector's device rendered at submission (D21 amended, D31). */
export interface InspectionReport {
  /** An object exists at the pinned name in the private inspection-reports
   * bucket. */
  present: boolean;
  /** Ten-minute signed URL; null when absent or when signing failed. The
   * bucket stays private (D19). */
  url: string | null;
  /** The name the browser saves under; identical to the phone's share-sheet
   * name (report_filename.ts). */
  filename: string;
}

export interface InspectionDetail {
  inspection: SubmittedInspection;
  items: InspectionItem[];
  photos: ItemPhoto[];
  report: InspectionReport;
}
