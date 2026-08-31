/// Runtime configuration, supplied at build time with --dart-define.
///
/// Only the anon key ever reaches this app. It is safe to ship *because* RLS is
/// enabled and forced on every table (docs/DATA_MODEL.md §5) — not because it is
/// secret. The service-role key must never appear here; it bypasses RLS entirely.
library;

class Env {
  const Env._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Fails closed. A missing configuration must stop the app with a visible
  /// error, never fall back to a stub or an empty client — a mock success path
  /// in production code would make every downstream claim untrustworthy.
  static void assertConfigured() {
    if (!isConfigured) {
      throw StateError(
        'SUPABASE_URL and SUPABASE_ANON_KEY are required. Run with:\n'
        '  flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...\n'
        'See .env.example at the repository root.',
      );
    }
  }
}
