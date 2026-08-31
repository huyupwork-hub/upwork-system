import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/config/env.dart';
import 'src/data/image_picker_photo_source.dart';
import 'src/data/photo_workflow.dart';
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

  final items = SupabaseInspectionItemsRepository(client);
  final photos = PhotoWorkflow(
    objects: SupabaseObjectStore(client),
    metadata: SupabasePhotoMetadataStore(client),
    currentUserId: () => client.auth.currentUser!.id,
  );
  final profiles = SupabaseProfileRepository(client);

  runApp(
    FieldProofApp(
      auth: SupabaseAuthRepository(client),
      profiles: profiles,
      inspections: SupabaseInspectionsRepository(client),
      items: items,
      photos: photos,
      source: ImagePickerPhotoSource(),
      reports: ReportService(
        loader: ReportLoader(items: items, photos: photos, profiles: profiles),
        renderer: const PdfReportRenderer(),
        sharer: const PrintingReportSharer(),
      ),
    ),
  );
}
