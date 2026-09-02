'use client';

import { useCallback, useEffect, useState } from 'react';

import type { GalleryPhoto } from '@/lib/data/types';

/**
 * The only client component in this console.
 *
 * Everything else is server-rendered, and deliberately so — search, filters and
 * sort all live in the URL. A lightbox is the one place where that would be
 * worse: paging through evidence with a full navigation per photograph is slow
 * enough to change how carefully someone looks. Keyboard navigation matters for
 * the same reason.
 *
 * It still writes nothing. D3 is about mutation, not about interactivity: this
 * reads what the server already sent and changes which of it is on screen.
 */
export function PhotoGallery({
  photos,
  initialFocus,
}: {
  photos: GalleryPhoto[];
  initialFocus?: string;
}) {
  const startIndex = initialFocus
    ? photos.findIndex((p) => p.id === initialFocus)
    : -1;
  const [open, setOpen] = useState<number | null>(
    startIndex >= 0 ? startIndex : null,
  );

  const close = useCallback(() => setOpen(null), []);
  const step = useCallback(
    (delta: number) =>
      setOpen((i) =>
        i === null ? null : Math.min(photos.length - 1, Math.max(0, i + delta)),
      ),
    [photos.length],
  );

  useEffect(() => {
    if (open === null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
      if (e.key === 'ArrowLeft') step(-1);
      if (e.key === 'ArrowRight') step(1);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, close, step]);

  if (photos.length === 0) {
    return (
      <p className="empty" data-testid="no-photos">
        No photographs have been attached to a submitted inspection yet.
      </p>
    );
  }

  const current = open === null ? null : photos[open];

  return (
    <>
      <div className="photo-grid">
        {photos.map((photo, i) => (
          <button
            key={photo.id}
            id={`photo-${photo.id}`}
            className="photo-card"
            type="button"
            onClick={() => setOpen(i)}
          >
            <span className="frame">
              {photo.url ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={photo.url} alt={photo.caption ?? photo.itemTitle} />
              ) : (
                // Stated, not skipped: a reviewer counting evidence needs to
                // know one could not be fetched.
                <span className="frame-missing">Could not be loaded</span>
              )}
            </span>
            <span className="photo-meta">
              <span className="t">{photo.itemTitle}</span>
              <span className="s">{photo.inspectionName}</span>
              {photo.caption ? <span className="s">{photo.caption}</span> : null}
            </span>
          </button>
        ))}
      </div>

      {current ? (
        <div className="lightbox" role="dialog" aria-modal="true" aria-label="Photograph" onClick={close}>
          <button className="lb-close" type="button" onClick={close} aria-label="Close">
            ✕
          </button>
          <div className="lb-stage" onClick={(e) => e.stopPropagation()}>
            <button
              className="lb-step"
              type="button"
              onClick={() => step(-1)}
              disabled={open === 0}
              aria-label="Previous photograph"
            >
              ‹
            </button>
            {current.url ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={current.url} alt={current.caption ?? current.itemTitle} />
            ) : (
              <p className="lb-missing">This photograph could not be loaded.</p>
            )}
            <button
              className="lb-step"
              type="button"
              onClick={() => step(1)}
              disabled={open === photos.length - 1}
              aria-label="Next photograph"
            >
              ›
            </button>
          </div>
          <div className="lb-meta" onClick={(e) => e.stopPropagation()}>
            {current.caption ? <p className="cap">{current.caption}</p> : null}
            <p className="ctx">
              {current.inspectionName} · {current.itemTitle}
            </p>
            <p className="ctx">
              {open! + 1} of {photos.length}
            </p>
          </div>
        </div>
      ) : null}
    </>
  );
}
