import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/core_options_builder.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/data/routing_list.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCore extends HiddifyCoreService {
  _FakeCore(super.ref);

  final sent = <SingboxConfigOption>[];
  final started = <String>[];

  @override
  TaskEither<String, Unit> changeOptions(SingboxConfigOption options) {
    sent.add(options);
    return TaskEither.of(unit);
  }

  @override
  TaskEither<String, Unit> validateConfigByPath(String path, String tempPath, bool debug) => TaskEither.of(unit);

  @override
  TaskEither<String, Unit> setup() => TaskEither.of(unit);

  @override
  TaskEither<ConnectionFailure, Unit> start(String path, String name, bool disableMemoryLimit) {
    started.add(path);
    return TaskEither.of(unit);
  }

  @override
  TaskEither<String, Unit> restart(String path, String name, bool disableMemoryLimit) {
    started.add(path);
    return TaskEither.of(unit);
  }
}

class _NoDataSource extends Fake implements ProfileDataSource {}

class _NoParser extends Fake implements ProfileParser {}

Uint8List _list(String suffix) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'version': 3,
      'rules': [
        {
          'domain_suffix': [suffix],
        },
      ],
    }),
  ),
);

ProfileEntity _profile(String id) => ProfileEntity.remote(
  id: id,
  active: true,
  name: id,
  url: 'https://sub.example.com/$id/',
  lastUpdate: DateTime(2026),
);

class _Harness {
  _Harness._(this.container, this.dir, this.store, this.core, this.builder);

  static Future<_Harness> create() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
    await container.read(sharedPreferencesProvider.future);
    final base = container.read(ConfigOptions.singboxConfigOptions);
    final dir = Directory.systemTemp.createTempSync('derbent_core_options_');
    final resolver = ProfilePathResolver(dir);
    final store = RoutingListStore(resolver.directory);
    final core = container.read(Provider((ref) => _FakeCore(ref)));
    final builder = CoreOptionsBuilder(
      configOptionRepository: ConfigOptionRepository(preferences: prefs, getConfigOptions: () => base),
      store: store,
    );
    return _Harness._(container, dir, store, core, builder);
  }

  final ProviderContainer container;
  final Directory dir;
  final RoutingListStore store;
  final _FakeCore core;
  final CoreOptionsBuilder builder;

  ProfilePathResolver get resolver => ProfilePathResolver(dir);

  ProfileRepositoryImpl profiles() => ProfileRepositoryImpl(
    profileDataSource: _NoDataSource(),
    profilePathResolver: resolver,
    singbox: core,
    profileParser: _NoParser(),
    optionsBuilder: builder,
  );

  ConnectionRepositoryImpl connection() => container.read(
    Provider(
      (ref) => ConnectionRepositoryImpl(
        ref: ref,
        directories: (baseDir: dir, workingDir: dir, tempDir: dir),
        singbox: core,
        configOptionRepository: builder.configOptionRepository,
        profilePathResolver: resolver,
        optionsBuilder: builder,
        routingStore: store,
      ),
    ),
  );

  Future<RoutingListState> storeList(String profileId, RoutingMode mode, String suffix) =>
      store.save(profileId, _list(suffix), mode: mode, count: 1);

  void dispose() {
    container.dispose();
    dir.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  setUp(() async => h = await _Harness.create());
  tearDown(() => h.dispose());

  group('validateConfig', () {
    test('sends the routing fields when that profile has a list', () async {
      final s = await h.storeList('p1', RoutingMode.whitelist, 'w.example.com');
      final res = await h.profiles().validateConfig('/x.json', '/x.tmp.json', null, false, profileId: 'p1').run();
      expect(res.isRight(), isTrue);
      final json = h.core.sent.single.toJson();
      expect(json['derbent-routing-mode'], 'whitelist');
      expect(json['derbent-routing-rule-set'], s.path);
    });

    test('sends no routing fields when that profile has no list', () async {
      await h.storeList('other', RoutingMode.whitelist, 'w.example.com');
      await h.profiles().validateConfig('/x.json', '/x.tmp.json', null, false, profileId: 'p1').run();
      final json = h.core.sent.single.toJson();
      expect(json.containsKey('derbent-routing-mode'), isFalse);
      expect(json.containsKey('derbent-routing-rule-set'), isFalse);
    });

    test('a profile override cannot set them', () async {
      await h
          .profiles()
          .validateConfig(
            '/x.json',
            '/x.tmp.json',
            jsonEncode({'derbent-routing-mode': 'full', 'derbent-routing-rule-set': '/tmp/x.json'}),
            false,
            profileId: 'p1',
          )
          .run();
      final json = h.core.sent.single.toJson();
      expect(json.containsKey('derbent-routing-mode'), isFalse);
      expect(json.containsKey('derbent-routing-rule-set'), isFalse);
    });
  });

  group('active profile changes while disconnected', () {
    test('the listener hands the new profile to refreshCoreOptions, not reconnect', () async {
      final reconnected = <ProfileEntity?>[];
      final refreshed = <ProfileEntity>[];
      Future<void> run(ProfileEntity? prev, ProfileEntity? next, {required bool connected}) => onActiveProfileChanged(
        previous: prev,
        next: next,
        connected: connected,
        reconnect: (p) async => reconnected.add(p),
        refreshCoreOptions: (p) async => refreshed.add(p),
      );
      await run(_profile('a'), _profile('b'), connected: false);
      expect(refreshed.map((p) => p.id), ['b']);
      expect(reconnected, isEmpty);
      await run(_profile('a'), _profile('b'), connected: true);
      expect(reconnected.map((p) => p?.id), ['b']);
      expect(refreshed, hasLength(1));
      await run(_profile('b'), _profile('b'), connected: false);
      await run(null, _profile('b'), connected: false);
      expect(refreshed, hasLength(1));
    });

    test('the options are rebuilt for the new profile, with its own list', () async {
      final a = await h.storeList('a', RoutingMode.full, 'a.example.com');
      final b = await h.storeList('b', RoutingMode.whitelist, 'b.example.com');
      final repo = h.connection();
      await repo.refreshCoreOptions(_profile('a')).run();
      expect(h.core.sent.last.toJson()['derbent-routing-rule-set'], a.path);
      final res = await repo.refreshCoreOptions(_profile('b')).run();
      expect(res.isRight(), isTrue);
      final json = h.core.sent.last.toJson();
      expect(json['derbent-routing-mode'], 'whitelist');
      expect(json['derbent-routing-rule-set'], b.path);
      expect(h.core.started, isEmpty, reason: 'nothing is started');
      await repo.refreshCoreOptions(_profile('c')).run();
      expect(h.core.sent.last.toJson().containsKey('derbent-routing-mode'), isFalse);
    });
  });

  group('connect', () {
    test('records the applied mode and removes only files the new core does not use', () async {
      final w = await h.storeList('p1', RoutingMode.whitelist, 'w.example.com');
      final repo = h.connection();
      expect((await repo.connect(_profile('p1'), false).run()).isRight(), isTrue);
      expect(h.core.sent.last.toJson()['derbent-routing-rule-set'], w.path);
      expect(h.container.read(appliedRoutingProvider)?.mode, RoutingMode.whitelist);

      // The panel switches the user to full mode while connected: the running file stays.
      final f = await h.storeList('p1', RoutingMode.full, 'f.example.com');
      expect(File(w.path).existsSync(), isTrue);
      expect(h.container.read(appliedRoutingProvider)?.mode, RoutingMode.whitelist);

      // The next connect applies full mode, and only then is the whitelist file removed.
      expect((await repo.reconnect(_profile('p1'), false).run()).isRight(), isTrue);
      expect(h.core.sent.last.toJson()['derbent-routing-mode'], 'full');
      expect(h.container.read(appliedRoutingProvider)?.mode, RoutingMode.full);
      expect(File(w.path).existsSync(), isFalse);
      expect(File(f.path).existsSync(), isTrue);
    });
  });
}
