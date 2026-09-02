import { AppShell } from '@/components/AppShell';
import { PhotoGallery } from '@/components/PhotoGallery';
import { currentDisplayName, requireAdmin } from '@/lib/auth';
import { SupabaseAdminRepository } from '@/lib/data/repository';
import { createClient } from '@/lib/supabase/server';

export const dynamic = 'force-dynamic';

/**
 * Every photograph attached to a submitted inspection, in one place.
 *
 * Scoped entirely by policy: the admin rules on `item_photos` and on
 * `storage.objects` both reach through the owning inspection and admit only
 * submitted ones, so a draft's evidence cannot appear here even though this
 * page asks for no status at all.
 *
 * `?focus=<id>` opens that photograph directly — it is what the thumbnails on
 * an inspection link to, so following one lands on the picture rather than at
 * the top of the grid.
 */
export default async function PhotosPage({
  searchParams,
}: {
  searchParams: { focus?: string };
}) {
  await requireAdmin();

  const repo = new SupabaseAdminRepository(createClient());
  const photos = await repo.listPhotos();
  const who = await currentDisplayName();

  return (
    <AppShell active="photos" who={who}>
      <div className="page-head">
        <nav className="breadcrumb" aria-label="Breadcrumb">
          <a href="/inspections">Inspections</a>
          <span className="sep" aria-hidden="true">
            /
          </span>
          <span className="here">Photos</span>
        </nav>
        <h1>Photos</h1>
        <p className="page-sub">
          {photos.length} attachment{photos.length === 1 ? '' : 's'} across all
          submitted inspections
        </p>
      </div>

      <div className="page-body">
        <PhotoGallery photos={photos} initialFocus={searchParams?.focus} />
      </div>
    </AppShell>
  );
}
