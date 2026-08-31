import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/config/env.dart';
import 'src/data/supabase_repositories.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Fails loudly if the build was not given a URL and anon key.
  Env.assertConfigured();

  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );

  final client = Supabase.instance.client;

  runApp(
    FieldProofApp(
      auth: SupabaseAuthRepository(client),
      profiles: SupabaseProfileRepository(client),
      inspections: SupabaseInspectionsRepository(client),
    ),
  );
}
