import { describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';

import { InspectionsTable } from '@/components/InspectionsTable';
import { InspectionDetailView } from '@/components/InspectionDetailView';
import type { InspectionDetail, SubmittedInspection } from '@/lib/data/types';

/**
 * What the parity pass added to the console, and the two claims it must not
 * make: that a count of zero is the same as a count not fetched, and that a
 * capability exists when it does not.
 */
const base: SubmittedInspection = {
  id: 'a1',
  siteName: 'Northgate Retail Park',
  siteAddress: '4 Northgate Way, Leeds',
  clientName: 'Cavendish Estates',
  inspectionDate: '2026-08-20',
  submittedAt: '2026-08-21T09:14:00Z',
  status: 'submitted',
  inspectorName: 'M. Reyes',
};

const html = (node: React.ReactElement) => renderToStaticMarkup(node);

describe('inspection queue density', () => {
  it('shows finding and severity counts when they were fetched', () => {
    const out = html(
      <InspectionsTable
        query=""
        inspections={[
          {
            ...base,
            findings: {
              total: 5,
              open: 2,
              bySeverity: { critical: 1, high: 2, medium: 0, low: 2 },
            },
          },
        ]}
      />,
    );

    expect(out).toContain('5');
    expect(out).toContain('2 open');
    expect(out).toContain('1 Critical');
    expect(out).toContain('2 High');
    expect(out).toContain('2 Low');
    // Only severities that occur. Four zeroes would make a single scuff look
    // as urgent as three critical defects.
    expect(out).not.toContain('Medium');
  });

  it('distinguishes "no findings" from "not fetched"', () => {
    const none = html(
      <InspectionsTable
        query=""
        inspections={[
          {
            ...base,
            findings: {
              total: 0,
              open: 0,
              bySeverity: { critical: 0, high: 0, medium: 0, low: 0 },
            },
          },
        ]}
      />,
    );
    expect(none).toContain('None');

    // Without the nested read there is no summary, and the table must say so
    // rather than printing a zero it did not count.
    const unknown = html(<InspectionsTable query="" inspections={[base]} />);
    expect(unknown).not.toContain('None');
    expect(unknown).toContain('—');
  });

  it('spells the severity level out beside its colour', () => {
    const out = html(
      <InspectionsTable
        query=""
        inspections={[
          {
            ...base,
            findings: {
              total: 1,
              open: 1,
              bySeverity: { critical: 1, high: 0, medium: 0, low: 0 },
            },
          },
        ]}
      />,
    );
    // Colour alone would exclude anyone who cannot separate these hues.
    expect(out).toContain('severity-critical');
    expect(out).toContain('1 Critical');
  });
});

describe('dependency notes', () => {
  const detail: InspectionDetail = {
    inspection: base,
    items: [
      {
        id: 'i1',
        sortOrder: 0,
        title: 'Water intrusion — ceiling',
        description: 'Staining above the east window.',
        area: 'Master Bedroom',
        severity: 'critical',
        status: 'open',
      },
    ],
    photos: [],
  };

  it('states the missing capability without implying a failure', () => {
    const out = html(<InspectionDetailView detail={detail} />);

    expect(out).toContain('Requires an email delivery provider');
    expect(out).toContain('Requires a contractor');
    expect(out).not.toMatch(/error|failed|unavailable/i);
  });

  it('does not add a control the console is not allowed to have', () => {
    // D23: the console is read-only and asserts it. A dependency note must be
    // copy, never a button that the database would refuse.
    const out = html(<InspectionDetailView detail={detail} />);
    expect(out).not.toMatch(/<button|<form|<input|<select|<textarea/);
  });
});
