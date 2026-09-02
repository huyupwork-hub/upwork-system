import { formatDate, formatTimestamp } from '@/lib/format';
import {
  SEVERITY_ORDER,
  type InspectionDetail,
  type InspectionItem,
  type ItemPhoto,
  type Severity,
} from '@/lib/data/types';

import { ItemStatusBadge, SeverityBadge, SubmittedPill } from './Badges';

const SEVERITY_LABEL: Record<Severity, string> = {
  critical: 'Critical',
  high: 'High',
  medium: 'Medium',
  low: 'Low',
};

/** Longer than this and the description is collapsed behind a disclosure. */
const LONG_DESCRIPTION = 120;

/**
 * Read-only review of one submitted inspection.
 *
 * There is deliberately no interactive element in this tree — no button, no
 * form, no input. That is asserted in test/render.test.tsx rather than left as
 * an intention, because "read-only" is easy to believe and easy to lose: a
 * single innocuous "Resolve" control added later would contradict D3 while the
 * database silently refused every click.
 *
 * Long descriptions are collapsed behind a native <details>, not a button, for
 * the same reason. A disclosure changes what is on screen and nothing on the
 * server; it is the one interaction this view can afford.
 *
 * It is report-oriented rather than a second PDF engine (D21). The Flutter
 * client remains the only thing that generates a document.
 */
export function InspectionDetailView({ detail }: { detail: InspectionDetail }) {
  const { inspection, items, photos } = detail;
  const photosFor = (itemId: string) => photos.filter((p) => p.itemId === itemId);

  const open = items.filter((i) => i.status === 'open').length;
  const resolved = items.length - open;
  const grouped = SEVERITY_ORDER.map((sev) => ({
    sev,
    rows: items.filter((i) => i.severity === sev),
  }));

  return (
    <article className="detail">
      <div className="page-head">
        <nav className="breadcrumb" aria-label="Breadcrumb">
          <a href="/inspections">Inspections</a>
          <span className="sep" aria-hidden="true">
            /
          </span>
          <span className="here">{inspection.siteName}</span>
        </nav>
        <div className="detail-head">
          <div>
            <h1>{inspection.siteName}</h1>
            {inspection.siteAddress ? (
              <p className="page-sub">{inspection.siteAddress}</p>
            ) : null}
          </div>
          <span className="head-actions">
            <SubmittedPill />
            <a className="open-link" href="/photos">
              Photos
            </a>
          </span>
        </div>
      </div>

      <div className="page-body">
        <div className="detail-grid">
          <div>
            <section className="side-card">
              <h2 className="card-head">Inspection info</h2>
              <dl>
                <div className="kv">
                  <dt>Client</dt>
                  <dd>{inspection.clientName ?? '—'}</dd>
                </div>
                <div className="kv">
                  <dt>Inspector</dt>
                  <dd>{inspection.inspectorName ?? '—'}</dd>
                </div>
                <div className="kv">
                  <dt>Date</dt>
                  <dd>{formatDate(inspection.inspectionDate)}</dd>
                </div>
                <div className="kv">
                  <dt>Submitted</dt>
                  <dd>{formatTimestamp(inspection.submittedAt)}</dd>
                </div>
              </dl>
            </section>

            <section className="side-card">
              <h2 className="card-head">Summary</h2>
              {SEVERITY_ORDER.map((sev) => (
                <p className="tally" key={sev}>
                  <span>{SEVERITY_LABEL[sev]}</span>
                  <span className={`n ${sev}`}>
                    {items.filter((i) => i.severity === sev).length}
                  </span>
                </p>
              ))}
              <p className="tally">
                <span>Total</span>
                <span className="n">{items.length}</span>
              </p>
              <p className="tally">
                <span>Resolved</span>
                <span className="n resolved">{resolved}</span>
              </p>
            </section>

            {/* Stated where a reviewer would otherwise look for a download. */}
            <p className="note-card">
              PDF reports are generated on the inspector&rsquo;s device. Cloud PDF
              storage is not connected.
            </p>

            {/* The two things this view visibly implies but cannot do. The
                reviewer console is read-only by design (D3) and generates no
                document of its own (D21) — saying so is more useful than a
                disabled button. */}
            <DependencyNote
              title="Issue this report to the client"
              requirement="Requires an email delivery provider"
            />
            <DependencyNote
              title="Raise a work order from a finding"
              requirement="Requires a work-order integration"
            />
          </div>

          <section className="items">
            <h2>
              Findings{' '}
              <span className="muted">
                ({items.length} total, {open} open)
              </span>
            </h2>

            {items.length === 0 ? (
              <p className="empty" data-testid="no-items">
                This inspection was submitted with no findings.
              </p>
            ) : (
              grouped.map(({ sev, rows }) =>
                rows.length === 0 ? null : (
                  <div className="sev-group" key={sev}>
                    <p className="sev-group-head">
                      <span className={`dot ${sev}`} aria-hidden="true" />
                      <span className="name">{SEVERITY_LABEL[sev]}</span>
                    </p>
                    <ol className="sev-list">
                      {rows.map((item) => (
                        <li key={item.id} data-testid="punch-item">
                          <Finding item={item} photos={photosFor(item.id)} />
                        </li>
                      ))}
                    </ol>
                  </div>
                ),
              )
            )}
          </section>
        </div>
      </div>
    </article>
  );
}

function Finding({ item, photos }: { item: InspectionItem; photos: ItemPhoto[] }) {
  const thumb = photos.find((p) => p.url);
  const unloadable = photos.filter((p) => !p.url);
  const description = item.description ?? '';
  const isLong = description.length > LONG_DESCRIPTION;

  return (
    <div className="finding">
      {thumb ? (
        // Links to the gallery rather than opening in place: a lightbox needs a
        // button, and this view is asserted to contain none.
        <a className="finding-thumb" href={`/photos?focus=${thumb.id}`}>
          {photos.length > 1 ? (
            // The design shows one thumbnail per finding. Saying how many more
            // there are keeps that layout without quietly hiding evidence.
            <span className="more-count">+{photos.length - 1}</span>
          ) : null}
          {/*
            A plain <img>, not next/image. These are time-limited signed URLs
            for objects in a private bucket: next/image would need each Supabase
            host in remotePatterns and would proxy private evidence through the
            Next server, caching it outside the storage policies that are
            supposed to govern it.
          */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={thumb.url ?? ''} alt={thumb.caption ?? item.title} />
        </a>
      ) : null}

      <div className="finding-body">
        <div className="finding-top">
          <h3>{item.title}</h3>
          <span className="badges">
            <SeverityBadge severity={item.severity} />
            <ItemStatusBadge status={item.status} />
          </span>
        </div>
        {item.area ? <p className="finding-where">{item.area}</p> : null}

        {description ? (
          isLong ? (
            <details className="finding-more">
              <summary>
                <span className="finding-desc">
                  {description.slice(0, LONG_DESCRIPTION - 2)}…
                </span>
                <span className="more">Show more</span>
              </summary>
              <p className="finding-desc">{description}</p>
            </details>
          ) : (
            <p className="finding-desc">{description}</p>
          )
        ) : null}

        {/* Never silently omit evidence: a photo that could not be signed is
            stated, so the reviewer knows the record is incomplete rather than
            assuming there was none. */}
        {unloadable.map((p) => (
          <p key={p.id} className="photo-missing">
            A photograph on this item could not be loaded.
          </p>
        ))}
      </div>
    </div>
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
