import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> overrideFor(Map<String, dynamic> panelHeaders) {
  final headers = ProfileParser.mergeAndValidateHeaders(panelHeaders, <String, dynamic>{});
  final result = ProfileParser.parse(
    tempFilePath: '',
    profile: ProfileEntity.remote(
      id: 'p1',
      active: true,
      name: '',
      url: 'https://example.com/sub',
      lastUpdate: DateTime.now(),
      populatedHeaders: headers,
    ),
  );
  final profile = result.getOrElse((l) => throw l) as RemoteProfileEntity;
  return jsonDecode(profile.profileOverride ?? '{}') as Map<String, dynamic>;
}

Future<ProviderContainer> containerWith(Map<String, Object> prefsValues) async {
  SharedPreferences.setMockInitialValues(prefsValues);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
  addTearDown(container.dispose);
  await container.read(sharedPreferencesProvider.future);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('panel-pushed settings', () {
    test('the three headers survive the filter and land in the override, interval as an int', () {
      final o = overrideFor({
        'url-test-interval': '120',
        'connection-test-url': 'https://p.example/c/generate_204',
        'direct-dns-address': 'https://1.1.1.1/dns-query',
      });
      expect(o['url-test-interval'], 120);
      expect(o['url-test-interval'], isA<int>());
      expect(o['connection-test-url'], 'https://p.example/c/generate_204');
      expect(o['direct-dns-address'], 'https://1.1.1.1/dns-query');
    });

    test('interval is clamped to 60..3600', () {
      expect(overrideFor({'url-test-interval': '5'})['url-test-interval'], 60);
      expect(overrideFor({'url-test-interval': '99999'})['url-test-interval'], 3600);
    });

    test('a non-numeric interval is dropped', () {
      expect(overrideFor({'url-test-interval': 'abc'}).containsKey('url-test-interval'), isFalse);
    });
  });

  group('defaults', () {
    test('non-China defaults', () async {
      final c = await containerWith({});
      expect(c.read(ConfigOptions.directDnsAddress), 'https://1.1.1.1/dns-query');
      expect(c.read(ConfigOptions.connectionTestUrl), 'https://cp.cloudflare.com');
      expect(c.read(ConfigOptions.urlTestInterval), const Duration(seconds: 120));
    });

    test('China keeps its direct DNS', () async {
      final c = await containerWith({'region': Region.cn.name});
      expect(c.read(ConfigOptions.directDnsAddress), '223.5.5.5');
    });
  });
}
