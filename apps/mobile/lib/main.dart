import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/config/env.dart';
import 'src/data/image_picker_photo_source.dart';
import 'src/data/photo_workflow.dart';
import 'src/offline/draft_store.dart';
import 'src/offline/draft_sync.dart';
import 'src/offline/offline_repositories.dart';
import 'src/offline/offline_status.dart';
import 'src/report/report_loader.dart';
import 'src/report/report_renderer.dart';
import 'src/report/report_service.dart';
import 'src/report/report_sharer.dart';
import 'src/data/supabase_repositories.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Fails loudly if the build was not given a URL and anon key.
  Env.assertConfigured();

  await Supabase.initialize(
    url: Env.supabaseUrl,
    // Supabase renamed the anon key to the publishable key; same value, and it
    // is still safe to ship only because RLS is enabled and forced everywhere.
    publishableKey: Env.supabaseAnonKey,
  );

  final client = Supabase.instance.client;

  final auth = SupabaseAuthRepository(client);
  final photos = PhotoWorkflow(
    objects: SupabaseObjectStore(client),
    metadata: SupabasePhotoMetadataStore(client),
    currentUserId: () => client.auth.currentUser!.id,
  );
  final profiles = SupabaseProfileRepository(client);

  // The offline queue. One notifier, one durable store, one push. The
  // repositories the UI holds are the offline-first ones, which delegate to the
  // Supabase ones whenever the server is reachable — so there is a single
  // create path, a single punch-list editor and a single history, not an online
  // set and an offline set to keep in agreement.
  final offlineStatus = OfflineStatusNotifier();
  final drafts = LocalDraftBook(
    const SharedPreferencesDraftStore(),
    onChanged: (pending) =>
        offlineStatus.setPendingIds(pending.map((d) => d.id).toSet()),
  );

  final items = OfflineFirstInspectionItemsRepository(
    remote: SupabaseInspectionItemsRepository(client),
    local: drafts,
  );
  final inspections = OfflineFirstInspectionsRepository(
    remote: SupabaseInspectionsRepository(client),
    local: drafts,
    auth: auth,
    status: offlineStatus,
  );
  final sync = DraftSync(
    local: drafts,
    sink: SupabaseDraftSink(client),
    auth: auth,
    status: offlineStatus,
  );

  runApp(
    FieldProofApp(
      auth: auth,
      profiles: profiles,
      inspections: inspections,
      items: items,
      photos: photos,
      source: ImagePickerPhotoSource(),
      reports: ReportService(
        loader: ReportLoader(items: items, photos: photos, profiles: profiles),
        renderer: const PdfReportRenderer(),
        sharer: const PrintingReportSharer(),
      ),
      offline: offlineStatus,
      onSync: sync.run,
    ),
  );
}
