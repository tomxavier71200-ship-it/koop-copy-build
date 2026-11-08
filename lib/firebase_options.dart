import 'package:firebase_core/firebase_core.dart';

/// Standalone copy deliberately has no production Firebase configuration.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform =>
      throw UnsupportedError('Firebase is not configured for KOOP COPY');
}
