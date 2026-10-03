import 'dart:async';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Shared-preferences key of the local Clash API secret.
const clashApiSecretPrefKey = "clash-api-secret";

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// 32 bytes from a cryptographically secure RNG, hex encoded (64 chars).
String generateClashApiSecret([Random? random]) {
  final rnd = random ?? Random.secure();
  return List<int>.generate(32, (_) => rnd.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Returns the persisted secret. On first run (or if the stored value is
/// missing/invalid) a new one is generated and persisted.
String readOrCreateClashApiSecret(SharedPreferences preferences) {
  final existing = preferences.getString(clashApiSecretPrefKey);
  if (existing != null && _hex64.hasMatch(existing)) return existing;
  final secret = generateClashApiSecret();
  // SharedPreferences updates its in-memory cache synchronously; the disk write completes in the background.
  unawaited(preferences.setString(clashApiSecretPrefKey, secret));
  return secret;
}
