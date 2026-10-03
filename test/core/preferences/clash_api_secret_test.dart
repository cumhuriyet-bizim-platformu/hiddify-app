import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/clash_api_secret.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestDirectories extends AppDirectories {
  _TestDirectories(this.dir);
  final Directory dir;

  @override
  Future<Directories> build() async => (baseDir: dir, workingDir: dir, tempDir: dir);
}

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generateClashApiSecret returns 32 random bytes as hex', () {
    final a = generateClashApiSecret();
    final b = generateClashApiSecret();
    expect(a, matches(_hex64));
    expect(b, matches(_hex64));
    expect(a, isNot(b));
  });

  test('secret is generated once and reused', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final first = readOrCreateClashApiSecret(prefs);
    final second = readOrCreateClashApiSecret(prefs);

    expect(first, matches(_hex64));
    expect(second, first);
    expect(prefs.getString(clashApiSecretPrefKey), first);
  });

  test('a missing or empty stored secret (upgrade) is replaced', () async {
    SharedPreferences.setMockInitialValues({clashApiSecretPrefKey: ''});
    final prefs = await SharedPreferences.getInstance();

    final secret = readOrCreateClashApiSecret(prefs);

    expect(secret, matches(_hex64));
    expect(prefs.getString(clashApiSecretPrefKey), secret);
  });

  test('the core config gets the persisted secret as web-secret', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tmp = await Directory.systemTemp.createTemp('derbent-clash-');
    addTearDown(() => tmp.delete(recursive: true));
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) async => prefs),
        appDirectoriesProvider.overrideWith(() => _TestDirectories(tmp)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    await container.read(appDirectoriesProvider.future);

    final json = container.read(ConfigOptions.singboxConfigOptions).toJson();

    expect(json['web-secret'], matches(_hex64));
    expect(json['web-secret'], prefs.getString(clashApiSecretPrefKey));
    expect(container.read(ConfigOptions.singboxConfigOptions).toJson()['web-secret'], json['web-secret']);
  });

  test('the secret is excluded from options export', () {
    expect(ConfigOptions.privatePreferencesKeys, contains('web-secret'));
    expect(ConfigOptions.preferences.containsKey('web-secret'), isFalse);
  });
}
