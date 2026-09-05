import { formatDate, formatTimestamp } from '@/lib/format';
import type { InspectionDetail } from '@/lib/data/types';

import { ItemStatusBadge, SeverityBadge, SubmittedPill } from './Badges';

/**
 * Read-only review of one submitted inspection.
 *
 * There is deliberately no interactive element in this tree — no button, no
 * form, no input. That is asserted in test/render.test.tsx rather than left as
 * an intention, because "read-only" is easy to believe and easy to lose: a
 * single innocuous "Resolve" control added later would contradict D3 while the
 * database silently refused every click.
 *
 * It is report-oriented rather than a second PDF engine (D21, D23); the
 * document it links to was rendered on the inspector's device and stored once
 * at submission (D31). The Flutter client remains the only thing that
 * generates a document; the console hands out a signed URL to that one.
 */
export function InspectionDetailView({ detail }: { detail: InspectionDetail }) {
  const { inspection, items, photos, report } = detail;
  const photosFor = (itemId: string) => photos.filter((p) => p.itemId === itemId);

  const open = items.filter((i) => i.status === 'open').length;

  return (
    <article className="detail">
      <header className="detail-head">
        <div>
          <h1>{inspection.siteName}</h1>
          {inspection.siteAddress ? (
            <p className="muted">{inspection.siteAddress}</p>
          ) : null}
        </div>
        <SubmittedPill />
      </header>

      <dl className="facts">
        <div>
          <dt>Client</dt>
          <dd>{inspection.clientName ?? '—'}</dd>
        </div>
        <div>
          <dt>Inspector</dt>
          <dd>{inspection.inspectorName ?? '—'}</dd>
        </div>
        <div>
          <dt>Inspection date</dt>
          <dd>{formatDate(inspection.inspectionDate)}</dd>
        </div>
        <div>
          <dt>Submitted</dt>
          <dd>{formatTimestamp(inspection.submittedAt)}</dd>
        </div>
      </dl>

      {/* Three states, never a blank: a link when the stored PDF signed, a
          statement when an object exists but could not be signed, and a
          statement when nothing was uploaded. "Not uploaded" and "could not be
          loaded" are different facts and the reviewer is told which (the photo
          rule applied to the document, D28). The link is a ten-minute bearer
          minted on the reviewer's session; `download` makes Storage send the
          file under the product's name, the one the phone's share sheet
          offers, instead of rendering an inspector's document inline on the
          storage origin. */}
      <section className="report" data-testid="report">
        <h2>PDF report</h2>
        {report.url ? (
          <p>
            <a
              className="report-link"
              href={report.url}
              download={report.filename}
              rel="noopener noreferrer"
              data-testid="report-link"
            >
              Download the PDF report
            </a>
            <span className="muted">
              {' '}
              — rendered on the inspector’s device when the inspection was
              submitted. The record above is authoritative; the link is valid
              for 10 minutes.
            </span>
          </p>
        ) : report.present ? (
          // "unloadable", not "unavailable": density.test.tsx forbids
          // /error|failed|unavailable/ over this view, and a test id must not
          // be able to trip it.
          <p className="report-missing" data-testid="report-unloadable">
            The PDF report exists but could not be loaded.
          </p>
        ) : (
          <p className="empty" data-testid="report-absent">
            No PDF report has been uploaded for this inspection yet. It is
            rendered on the inspector’s device and uploaded when the inspection
            is submitted.
          </p>
        )}
      </section>

      <section className="items">
        <h2>
          Findings <span className="muted">({items.length} total, {open} open)</span>
        </h2>

        {items.length === 0 ? (
          <p className="empty" data-testid="no-items">
            This inspection was submitted with no findings.
          </p>
        ) : (
          <ol className="item-list">
            {items.map((item) => {
              const itemPhotos = photosFor(item.id);
              return (
                <li key={item.id} className="item" data-testid="punch-item">
                  <div className="item-head">
                    <h3>{item.title}</h3>
                    <span className="badges">
                      <SeverityBadge severity={item.severity} />
                      <ItemStatusBadge status={item.status} />
                    </span>
                  </div>
                  {item.area ? <p className="muted">{item.area}</p> : null}
                  {item.description ? <p>{item.description}</p> : null}

                  {itemPhotos.length > 0 ? (
                    <div className="photos">
                      {itemPhotos.map((photo) =>
                        photo.url ? (
                          <figure key={photo.id} className="photo">
                            {/*
                              A plain <img>, not next/image. These are
                              time-limited signed URLs for objects in a private
                              bucket: next/image would need each Supabase host in
                              remotePatterns and would proxy private evidence
                              through the Next server, caching it outside the
                              storage policies that are supposed to govern it.
                            */}
                            {/* eslint-disable-next-line @next/next/no-img-element */}
                            <img src={photo.url} alt={photo.caption ?? item.title} />
                            {photo.caption ? (
                              <figcaption>{photo.caption}</figcaption>
                            ) : null}
                          </figure>
                        ) : (
                          // Never silently omit evidence: a photo that could not
                          // be signed is stated, so the reviewer knows the record
                          // is incomplete rather than assuming there was none.
                          <p key={photo.id} className="photo-missing">
                            A photograph on this item could not be loaded.
                          </p>
                        ),
                      )}
                    </div>
                  ) : null}
                </li>
              );
            })}
          </ol>
        )}
      </section>

      {/* The two things this view visibly implies but cannot do. The reviewer
          console is read-only by design (D3) and generates no document of its
          own — the PDF above was rendered on the phone and stored once (D21,
          D31) — saying so is more useful than a disabled button. */}
      <DependencyNote
        title="Issue this report to the client"
        requirement="Requires an email delivery provider"
      />
      <DependencyNote
        title="Raise a work order from a finding"
        requirement="Requires a work-order integration"
      />
    </article>
  );
}

/**
 * A capability the design implies and the product does not have.
 *
 * Rendered as product copy rather than hidden: a reviewer who expects to press
 * "send" should find out here, from the interface, rather than by pressing
 * something that quietly does nothing.
 */
function DependencyNote({
  title,
  requirement,
}: {
  title: string;
  requirement: string;
}) {
  return (
    <div className="dependency-note" data-testid="dependency-note">
      <span className="mark" aria-hidden="true">
        i
      </span>
      <span>
        <span className="title block">{title}</span>
        <span className="req">{requirement}</span>
      </span>
    </div>
  );
}
