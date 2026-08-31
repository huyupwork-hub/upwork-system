import type { ItemStatus, Severity } from '@/lib/data/types';

/**
 * The four accepted severities and the two accepted item states (D14). No
 * colour carries meaning on its own — each badge is also labelled — so the
 * console stays readable when printed or viewed by someone who cannot
 * distinguish the hues.
 */

const SEVERITY_LABEL: Record<Severity, string> = {
  critical: 'Critical',
  high: 'High',
  medium: 'Medium',
  low: 'Low',
};

export function SeverityBadge({ severity }: { severity: Severity }) {
  return (
    <span className={`badge severity-${severity}`}>
      {SEVERITY_LABEL[severity] ?? severity}
    </span>
  );
}

export function ItemStatusBadge({ status }: { status: ItemStatus }) {
  return (
    <span className={`badge item-${status}`}>
      {status === 'resolved' ? 'Resolved' : 'Open'}
    </span>
  );
}

export function SubmittedPill() {
  return <span className="badge submitted">Submitted</span>;
}
