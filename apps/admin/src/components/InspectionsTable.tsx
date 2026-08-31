import { formatDate, formatTimestamp } from '@/lib/format';
import type { SubmittedInspection } from '@/lib/data/types';

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
          <th scope="col">Site</th>
          <th scope="col">Client</th>
          <th scope="col">Inspector</th>
          <th scope="col">Inspection date</th>
          <th scope="col">Submitted</th>
          <th scope="col">Status</th>
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
            <td>{formatDate(row.inspectionDate)}</td>
            <td>{formatTimestamp(row.submittedAt)}</td>
            <td>
              <SubmittedPill />
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
