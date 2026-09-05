import { formatDate, formatTimestamp } from '@/lib/format';
import {
  SEVERITY_ORDER,
  type FindingSummary,
  type Severity,
  type SubmittedInspection,
} from '@/lib/data/types';

import { SubmittedPill } from './Badges';

/**
 * The submitted queue. Presentational only — it is handed rows and renders
 * them, so a test can assert what a reviewer sees without a database.
 *
 * Every row is submitted by construction (the repository filters, and the admin
 * policy scopes). The status column is still shown rather than assumed: a
 * reviewer should be able to see the state of what they are reading, not infer
 * it from the fact that the page loaded.
 */
export function InspectionsTable({
  inspections,
  query,
}: {
  inspections: SubmittedInspection[];
  query: string;
}) {
  if (inspections.length === 0) {
    return (
      <p className="empty" data-testid={query ? 'no-matches' : 'no-submitted'}>
        {query
          ? `No submitted inspections match “${query}”.`
          : 'No inspections have been submitted yet.'}
      </p>
    );
  }

  return (
    <table className="table" data-testid="inspections-table">
      <thead>
        <tr>
          <th scope="col">Property</th>
          <th scope="col">Client</th>
          <th scope="col">Inspector</th>
          <th scope="col">Date</th>
          <th scope="col">Findings</th>
          <th scope="col">Severity</th>
          <th scope="col">Submitted</th>
          <th scope="col">Status</th>
          <th scope="col">Report</th>
        </tr>
      </thead>
      <tbody>
        {inspections.map((row) => (
          <tr key={row.id} data-testid="inspection-row">
            <td>
              <a className="row-link" href={`/inspections/${row.id}`}>
                {row.siteName}
              </a>
              {row.siteAddress ? (
                <span className="muted block">{row.siteAddress}</span>
              ) : null}
            </td>
            <td>{row.clientName ?? '—'}</td>
            <td>{row.inspectorName ?? '—'}</td>
            <td className="nowrap">{formatDate(row.inspectionDate)}</td>
            <td className="nowrap">
              <FindingsCell findings={row.findings} />
            </td>
            <td>
              <SeverityCounts findings={row.findings} />
            </td>
            <td className="nowrap">{formatTimestamp(row.submittedAt)}</td>
            <td>
              <SubmittedPill />
            </td>
            <td className="nowrap">
              <ReportCell hasReport={row.hasReport} />
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/**
 * "5 findings · 2 open", or a dash when the counts were not fetched.
 *
 * A reviewer triaging a queue wants to know how much is in a record before
 * opening it. Both numbers are counted from the inspection's own items; neither
 * is stored.
 */
function FindingsCell({ findings }: { findings?: FindingSummary }) {
  if (!findings) return <span className="muted">—</span>;
  if (findings.total === 0) return <span className="muted">None</span>;

  return (
    <span>
      {findings.total}
      {findings.open > 0 ? (
        <span className="muted"> · {findings.open} open</span>
      ) : (
        <span className="muted"> · all resolved</span>
      )}
    </span>
  );
}

/**
 * Severity counts, worst first, and only the ones that occur.
 *
 * Four zeroes would be noise, and would make an inspection with a single scuff
 * look as urgent as one with three critical defects. The number is spelled out
 * beside the colour for the same reason the mobile chip is: colour alone
 * excludes anyone who cannot separate these hues.
 */
function SeverityCounts({ findings }: { findings?: FindingSummary }) {
  if (!findings || findings.total === 0) return <span className="muted">—</span>;

  const present = SEVERITY_ORDER.filter((s) => findings.bySeverity[s] > 0);
  return (
    <span className="sev-counts">
      {present.map((s) => (
        <span key={s} className={`sev-count severity-${s}`}>
          <i aria-hidden="true" />
          {findings.bySeverity[s]} {SEVERITY_LABEL[s]}
        </span>
      ))}
    </span>
  );
}

/**
 * "PDF", "Not yet", or a dash when the reports folder was not or could not be
 * listed.
 *
 * The dash is the FindingSummary rule applied to the document: "Not yet" is a
 * claim that nothing was uploaded, and the console may only make it after it
 * looked (D28). A folder listing that errored, or that filled its page, says
 * nothing either way, so neither does the cell.
 */
function ReportCell({ hasReport }: { hasReport?: boolean }) {
  if (hasReport === undefined) return <span className="muted">—</span>;
  if (!hasReport) return <span className="muted">Not yet</span>;
  return <span>PDF</span>;
}

const SEVERITY_LABEL: Record<Severity, string> = {
  critical: 'Critical',
  high: 'High',
  medium: 'Medium',
  low: 'Low',
};
