import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';

import { InspectionDetailView } from '@/components/InspectionDetailView';
import { InspectionsTable } from '@/components/InspectionsTable';
import type {
  InspectionDetail,
  SubmittedInspection,
} from '@/lib/data/types';

/**
 * Rendered as static markup: no DOM, no client, no Supabase. These components
 * are handed data and nothing else, which is what makes "what does a reviewer
 * actually see" a question a test can answer.
 */

const submitted: SubmittedInspection = {
  id: 'a2',
  inspectorId: 'u',
  siteName: 'Northgate Retail Park',
  siteAddress: '4 Northgate Way, Leeds',
  clientName: 'Cavendish Estates',
  inspectionDate: '2026-08-22',
  submittedAt: '2026-08-22T14:00:00+00:00',
  status: 'submitted',
  inspectorName: 'Inspector Alpha',
};

const detail: InspectionDetail = {
  inspection: submitted,
  items: [
    {
      id: 'i1',
      sortOrder: 0,
      title: 'Exposed wiring at junction box',
      description: 'Cover plate missing; conductors visible.',
      area: 'Plant room',
      severity: 'critical',
      status: 'open',
    },
    {
      id: 'i2',
      sortOrder: 1,
      title: 'Fire door does not latch',
      description: null,
      area: 'Corridor B',
      severity: 'high',
      status: 'resolved',
    },
  ],
  photos: [
    {
      id: 'p1',
      itemId: 'i1',
      caption: 'Junction box, cover removed',
      url: 'https://example.test/signed/p1.jpg?token=abc',
    },
  ],
  report: {
    present: true,
    url: 'https://example.test/signed/u/a2/report.pdf?token=def',
    filename: 'fieldproof-northgate-retail-park-20260822-a2.pdf',
  },
};

describe('submitted inspections list', () => {
  it('shows every accepted column for a submitted row', () => {
    const html = renderToStaticMarkup(
      <InspectionsTable inspections={[submitted]} query="" />,
    );

    expect(html).toContain('Northgate Retail Park');
    expect(html).toContain('4 Northgate Way, Leeds');
    expect(html).toContain('Cavendish Estates');
    expect(html).toContain('Inspector Alpha');
    expect(html).toContain('22 Aug 2026');
    expect(html).toContain('14:00 UTC');
    expect(html).toContain('Submitted');
    expect(html).toContain('/inspections/a2');
  });

  it('distinguishes "nothing submitted" from "nothing matched"', () => {
    const empty = renderToStaticMarkup(
      <InspectionsTable inspections={[]} query="" />,
    );
    expect(empty).toContain('no-submitted');
    expect(empty).toContain('No inspections have been submitted yet.');

    const noMatch = renderToStaticMarkup(
      <InspectionsTable inspections={[]} query="zzzz" />,
    );
    expect(noMatch).toContain('no-matches');
    expect(noMatch).toContain('zzzz');
  });

  it('renders one row per inspection and no more', () => {
    const html = renderToStaticMarkup(
      <InspectionsTable
        inspections={[submitted, { ...submitted, id: 'a3', siteName: 'Second' }]}
        query=""
      />,
    );
    expect(html.split('data-testid="inspection-row"').length - 1).toBe(2);
  });

  it('says PDF, Not yet, or nothing at all about the report', () => {
    // One row per table so the words can be attributed to the row: 'PDF' and
    // 'Not yet' appear nowhere else in the queue, and the dash is shared with
    // the not-fetched findings cell, which is the same rule (D28).
    const row = (hasReport?: boolean) =>
      renderToStaticMarkup(
        <InspectionsTable inspections={[{ ...submitted, hasReport }]} query="" />,
      );

    expect(row(true)).toContain('PDF');
    expect(row(true)).not.toContain('Not yet');

    expect(row(false)).toContain('Not yet');
    expect(row(false)).not.toContain('PDF');

    // Not listed, or could not be listed: neither claim, a dash. Counted,
    // not searched for: the fixture's unfetched findings already put dashes
    // in every row, so "contains a dash" would pass with an empty cell. The
    // undecided row carries exactly one more, the Report cell's own.
    const dashes = (html: string) => (html.match(/—/g) ?? []).length;
    expect(row(undefined)).not.toContain('PDF');
    expect(row(undefined)).not.toContain('Not yet');
    expect(dashes(row(undefined))).toBe(dashes(row(true)) + 1);
    expect(dashes(row(undefined))).toBe(dashes(row(false)) + 1);
  });
});

describe('inspection detail is read-only', () => {
  const html = renderToStaticMarkup(<InspectionDetailView detail={detail} />);

  it('shows the inspection facts', () => {
    expect(html).toContain('Northgate Retail Park');
    expect(html).toContain('4 Northgate Way, Leeds');
    expect(html).toContain('Cavendish Estates');
    expect(html).toContain('Inspector Alpha');
    expect(html).toContain('22 Aug 2026');
    expect(html).toContain('14:00 UTC');
  });

  it('shows items with severity, state, area and description', () => {
    expect(html).toContain('Exposed wiring at junction box');
    expect(html).toContain('Cover plate missing; conductors visible.');
    expect(html).toContain('Plant room');
    expect(html).toContain('Critical');
    expect(html).toContain('Open');
    expect(html).toContain('Fire door does not latch');
    expect(html).toContain('Resolved');
    expect(html.split('data-testid="punch-item"').length - 1).toBe(2);
  });

  it('shows photos through their signed URL', () => {
    expect(html).toContain('https://example.test/signed/p1.jpg?token=abc');
    expect(html).toContain('Junction box, cover removed');
  });

  it('states an unloadable photo instead of omitting it', () => {
    const withBroken = renderToStaticMarkup(
      <InspectionDetailView
        detail={{
          ...detail,
          photos: [{ id: 'p2', itemId: 'i1', caption: null, url: null }],
        }}
      />,
    );
    expect(withBroken).toContain('could not be loaded');
  });

  it('links the stored report by its signed URL under the product filename', () => {
    // Both attributes read from the one element, not from anywhere in the
    // page: an href on some other anchor would not prove the report link.
    const link = html.match(/<a[^>]*data-testid="report-link"[^>]*>/)?.[0] ?? '';
    expect(link).toContain(
      'href="https://example.test/signed/u/a2/report.pdf?token=def"',
    );
    expect(link).toContain(
      'download="fieldproof-northgate-retail-park-20260822-a2.pdf"',
    );
    expect(html).toContain('Download the PDF report');
    expect(html).not.toContain('report-absent');
    expect(html).not.toContain('report-unloadable');
  });

  it('states an absent report as not uploaded, without a link', () => {
    const absent = renderToStaticMarkup(
      <InspectionDetailView
        detail={{ ...detail, report: { ...detail.report, present: false, url: null } }}
      />,
    );
    expect(absent).toContain('data-testid="report-absent"');
    expect(absent).toContain('No PDF report has been uploaded for this inspection yet.');
    expect(absent).not.toContain('report-link');
    expect(absent).not.toContain('report-unloadable');
  });

  it('states an unloadable report instead of calling it absent', () => {
    // An object exists but did not sign. "Not uploaded" would be a claim the
    // listing already disproved (D28); the reviewer is told which fact holds.
    const unloadable = renderToStaticMarkup(
      <InspectionDetailView
        detail={{ ...detail, report: { ...detail.report, present: true, url: null } }}
      />,
    );
    expect(unloadable).toContain('data-testid="report-unloadable"');
    expect(unloadable).toContain('The PDF report exists but could not be loaded.');
    expect(unloadable).not.toContain('report-link');
    expect(unloadable).not.toContain('report-absent');
    expect(unloadable).not.toContain('has been uploaded');
  });

  it('contains no control that could mutate anything', () => {
    // D3: admin is read-only. A button here would be refused by the database,
    // but it would still be a lie told to the reviewer — and the moment someone
    // wires it up, the console stops matching the contract.
    for (const tag of ['<button', '<form', '<input', '<select', '<textarea']) {
      expect(html).not.toContain(tag);
    }
    // Matched as a complete element label (`>Edit<`), not as a substring.
    // 'Resolved' and 'Submitted' are read-only *status* words that legitimately
    // appear here; a substring check would confuse a label with a control and
    // fail on correct markup.
    for (const verb of ['Edit', 'Delete', 'Resolve', 'Reopen', 'Submit', 'Unsubmit', 'Upload']) {
      expect(html).not.toContain(`>${verb}<`);
    }
  });
});
