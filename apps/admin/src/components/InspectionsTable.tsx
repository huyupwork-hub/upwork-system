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
 *
 * The reference design carries a Sync column. It is absent here on purpose: an
 * unsynced draft has by definition never reached the server, so nothing the
 * console can see is ever anything but synced, and the column would read the
 * same word on every row forever.
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
          <th scope="col">
            <span className="sr-only">Open</span>
          </th>
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
              <SeverityCell findings={row.findings} />
            </td>
            <td className="nowrap">{formatTimestamp(row.submittedAt)}</td>
            <td>
              <SubmittedPill />
            </td>
            <td className="nowrap">
              <a className="open-link" href={`/inspections/${row.id}`}>
                Open
              </a>
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
 * The design's proportional bar, above the counts in words.
 *
 * The bar alone would be colour carrying meaning on its own, which excludes
 * anyone who cannot separate these hues — and a test named "spells the severity
 * level out beside its colour" exists to stop exactly that regression. So the
 * bar is an addition to the words, never a replacement for them.
 *
 * Only severities that occur appear, in either form. Four zeroes would be noise
 * and would make an inspection with a single scuff look as urgent as one with
 * three critical defects.
 */
function SeverityCell({ findings }: { findings?: FindingSummary }) {
  if (!findings || findings.total === 0) return <span className="muted">—</span>;

  const present = SEVERITY_ORDER.filter((s) => findings.bySeverity[s] > 0);
  const spoken = present
    .map((s) => `${findings.bySeverity[s]} ${SEVERITY_LABEL[s]}`)
    .join(', ');

  return (
    <span className="sev-cell">
      <span className="sevbar">
        <span className="sevbar-track" role="img" aria-label={spoken} title={spoken}>
          {present.map((s) => (
            <span
              key={s}
              className={`sevbar-seg ${s}`}
              style={{ width: `${(findings.bySeverity[s] / findings.total) * 100}%` }}
            />
          ))}
        </span>
        <span className="count">{findings.total}</span>
      </span>
      <span className="sev-counts">
        {present.map((s) => (
          <span key={s} className={`sev-count severity-${s}`}>
            <i aria-hidden="true" />
            {findings.bySeverity[s]} {SEVERITY_LABEL[s]}
          </span>
        ))}
      </span>
    </span>
  );
}

const SEVERITY_LABEL: Record<Severity, string> = {
  critical: 'Critical',
  high: 'High',
  medium: 'Medium',
  low: 'Low',
};
