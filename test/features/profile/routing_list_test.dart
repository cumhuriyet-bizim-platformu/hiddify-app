import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/home/widget/routing_status_line.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/data/routing_list.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final sub = Uri.parse('https://sub.example.com/p/uuid-1/');
const listUrl = 'https://sub.example.com/p/uuid-1/routing.json';

/// A list in the panel's exact output shape (lists.py to_ruleset_json).
Uint8List listBody({
  List<String> domain = const [],
  List<String> suffix = const ['example.com', 'news.example.org'],
  List<String> cidr = const ['1.2.3.0/24'],
  Object version = 3,
  Map<String, Object>? extraRuleKeys,
  Map<String, Object>? extraTop,
}) {
  final rule = <String, Object>{'domain': domain, 'domain_suffix': suffix, 'ip_cidr': cidr, ...?extraRuleKeys};
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': version,
        'rules': [rule],
        ...?extraTop,
      }),
    ),
  );
}

String hex(List<int> b) => sha256.convert(b).toString();

RoutingHeader header(List<int> b, {String mode = 'whitelist', String url = listUrl, String? sha}) =>
    RoutingHeader.parse('mode=$mode; url=$url; sha256=${sha ?? hex(b)}')!;

RoutingRejection? rejection(RoutingValidation v) => switch (v) {
  RoutingRejected(:final reason) => reason,
  RoutingOk() => null,
};

Future<SingboxConfigOption> baseOptions() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
  addTearDown(container.dispose);
  await container.read(sharedPreferencesProvider.future);
  return container.read(ConfigOptions.singboxConfigOptions);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RoutingHeader.parse', () {
    test('the panel format', () {
      final h = RoutingHeader.parse('mode=whitelist; url=$listUrl; sha256=${'a' * 64}')!;
      expect(h.mode, RoutingMode.whitelist);
      expect(h.url, Uri.parse(listUrl));
      expect(h.sha256, 'a' * 64);
    });

    test('lenient: any order, extra spaces, upper-case hex, unknown keys ignored', () {
      final h = RoutingHeader.parse('  sha256 = ${'AB' * 32} ;url= $listUrl?x=1 ;  mode = full ; future=1 ')!;
      expect(h.mode, RoutingMode.full);
      expect(h.url.toString(), '$listUrl?x=1');
      expect(h.sha256, 'ab' * 32);
    });

    test('missing or bad fields → null', () {
      expect(RoutingHeader.parse(''), isNull);
      expect(RoutingHeader.parse('mode=whitelist; url=$listUrl'), isNull);
      expect(RoutingHeader.parse('mode=split; url=$listUrl; sha256=${'a' * 64}'), isNull);
      expect(RoutingHeader.parse('mode=full; url=$listUrl; sha256=abc'), isNull);
      expect(RoutingHeader.parse('mode=full; url=not a url; sha256=${'a' * 64}'), isNull);
    });
  });

  group('RoutingListValidator', () {
    test('a valid body is accepted with the right count', () {
      final b = listBody(domain: ['www.example.net'], cidr: ['1.2.3.0/24', '2a01:4f8::/32']);
      final v = RoutingListValidator.validate(b, header(b), sub);
      expect(v, isA<RoutingOk>());
      expect((v as RoutingOk).count, 5);
    });

    test('a host other than the subscription host is rejected', () {
      final b = listBody();
      final v = RoutingListValidator.validate(b, header(b, url: 'https://evil.example.net/p/uuid-1/routing.json'), sub);
      expect(rejection(v), RoutingRejection.host);
    });

    test('the port must be the subscription port (no port means 443)', () {
      final b = listBody();
      final other = header(b, url: 'https://sub.example.com:8443/p/uuid-1/routing.json');
      expect(rejection(RoutingListValidator.validate(b, other, sub)), RoutingRejection.host);
      expect(RoutingListValidator.checkUrl(other, sub), isNotNull);
      final explicit443 = header(b, url: 'https://sub.example.com:443/p/uuid-1/routing.json');
      expect(RoutingListValidator.validate(b, explicit443, sub), isA<RoutingOk>());
      final sub8443 = Uri.parse('https://sub.example.com:8443/p/uuid-1/');
      expect(RoutingListValidator.validate(b, other, sub8443), isA<RoutingOk>());
      expect(rejection(RoutingListValidator.validate(b, header(b), sub8443)), RoutingRejection.host);
    });

    test('http is rejected', () {
      final b = listBody();
      final v = RoutingListValidator.validate(b, header(b, url: 'http://sub.example.com/p/uuid-1/routing.json'), sub);
      expect(rejection(v), RoutingRejection.scheme);
    });

    test('a body over 256 KB is rejected', () {
      final big = listBody(suffix: [for (var i = 0; i < 1950; i++) '${'a' * 60}$i.${'b' * 60}.example.com']);
      expect(big.length, greaterThan(256 * 1024));
      expect(rejection(RoutingListValidator.validate(big, header(big), sub)), RoutingRejection.tooLarge);
    });

    test('a sha256 mismatch is rejected', () {
      final b = listBody();
      expect(rejection(RoutingListValidator.validate(b, header(b, sha: 'f' * 64), sub)), RoutingRejection.hash);
    });

    test('any key other than domain, domain_suffix and ip_cidr is rejected', () {
      for (final extra in <Map<String, Object>>[
        {
          'domain_regex': ['.*'],
        },
        {'outbound': 'direct'},
        {'server': 'x'},
        {
          'domain_keyword': ['x'],
        },
        {
          'process_name': ['x'],
        },
        {'invert': true},
      ]) {
        final b = listBody(extraRuleKeys: extra);
        expect(rejection(RoutingListValidator.validate(b, header(b), sub)), RoutingRejection.key, reason: '$extra');
      }
      final top = listBody(extraTop: {'outbound': 'direct'});
      expect(rejection(RoutingListValidator.validate(top, header(top), sub)), RoutingRejection.key);
    });

    test('more than 2,000 entries in total is rejected', () {
      final b = listBody(
        suffix: [for (var i = 0; i < 1500; i++) 'h$i.example.com'],
        domain: [for (var i = 0; i < 501; i++) 'd$i.example.com'],
        cidr: [],
      );
      expect(rejection(RoutingListValidator.validate(b, header(b), sub)), RoutingRejection.tooManyEntries);
      final ok = listBody(suffix: [for (var i = 0; i < 2000; i++) 'h$i.example.com'], cidr: []);
      expect(RoutingListValidator.validate(ok, header(ok), sub), isA<RoutingOk>());
    });

    test('an invalid hostname is rejected', () {
      for (final bad in [
        '*.x.com',
        'https://x.com/a',
        'x.com:443',
        'x',
        '-x.com',
        'x_y.com',
        'X..com',
        '1.2.3.4',
        'x.123',
        '',
      ]) {
        final b = listBody(suffix: ['ok.example.com', bad]);
        expect(rejection(RoutingListValidator.validate(b, header(b), sub)), RoutingRejection.hostname, reason: bad);
      }
    });

    test('an invalid CIDR is rejected', () {
      for (final bad in ['1.2.3.4', '1.2.3.0/33', '300.1.1.0/24', 'x/8', '2a01:4f8::/129', '1.2.3.0/-1', '']) {
        final b = listBody(cidr: [bad]);
        expect(rejection(RoutingListValidator.validate(b, header(b), sub)), RoutingRejection.cidr, reason: bad);
      }
    });

    test('version other than 3 is rejected', () {
      for (final v in [1, 2, 4, '3']) {
        final b = listBody(version: v);
        expect(rejection(RoutingListValidator.validate(b, header(b), sub)), RoutingRejection.version, reason: '$v');
      }
    });

    test('malformed JSON, no rules, or no entries at all is rejected', () {
      final junk = Uint8List.fromList(utf8.encode('{"version":3,"rules":'));
      expect(rejection(RoutingListValidator.validate(junk, header(junk), sub)), RoutingRejection.format);
      final noRules = Uint8List.fromList(utf8.encode('{"version":3,"rules":[]}'));
      expect(rejection(RoutingListValidator.validate(noRules, header(noRules), sub)), RoutingRejection.empty);
      // An empty rule would match everything in sing-box.
      final empty = listBody(suffix: [], cidr: []);
      expect(rejection(RoutingListValidator.validate(empty, header(empty), sub)), RoutingRejection.empty);
      final notList = listBody(extraRuleKeys: {'domain': 'x.example.com'});
      expect(rejection(RoutingListValidator.validate(notList, header(notList), sub)), RoutingRejection.format);
    });
  });

  group('catch-all CIDRs', () {
    test('shorter than /8 (IPv4) or /16 (IPv6) is rejected', () {
      for (final bad in ['0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/7', '::/0', '2000::/3', '2a00::/15']) {
        final b = listBody(cidr: [bad]);
        expect(rejection(RoutingListValidator.validate(b, header(b), sub)), RoutingRejection.cidr, reason: bad);
      }
      for (final ok in ['10.0.0.0/8', '1.2.3.4/32', '2a01::/16', '2a01:4f8::1/128']) {
        final b = listBody(cidr: [ok]);
        expect(RoutingListValidator.validate(b, header(b), sub), isA<RoutingOk>(), reason: ok);
      }
    });
  });

  group('refresh flow', () {
    late Directory dir;
    late RoutingListStore store;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('derbent_routing_');
      store = RoutingListStore(dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    RoutingListRefresher refresher(Uint8List Function() serve, {List<Uri>? log}) => RoutingListRefresher(
      store: store,
      download: (url, path, maxBytes) async {
        log?.add(url);
        await File(path).writeAsBytes(serve());
      },
    );

    String raw(RoutingHeader h) => 'mode=${h.mode.name}; url=${h.url}; sha256=${h.sha256}';

    test('a valid list is stored next to the profile and reported', () async {
      final b = listBody();
      final log = <Uri>[];
      final s = await refresher(
        () => b,
        log: log,
      ).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      expect(log, [Uri.parse(listUrl)]);
      expect(s, isNotNull);
      expect(s!.mode, RoutingMode.whitelist);
      expect(s.count, 3);
      expect(p_isAbsolute(s.path), isTrue);
      expect(File(s.path).readAsBytesSync(), b);
      expect(File(s.path).parent.path, dir.absolute.path);
      final again = await store.current('p1');
      expect(again?.sha256, hex(b));
    });

    test('staleHashKeepsPreviousValidFile', () async {
      final old = listBody(suffix: ['old.example.com']);
      await refresher(() => old).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(old)));
      // A cache served the old subscription (old hash) while the file on the server is new.
      final fresh = listBody(suffix: ['new.example.com']);
      final s = await refresher(
        () => fresh,
      ).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(old)));
      expect(s, isNotNull);
      expect(s!.sha256, hex(old));
      expect(File(s.path).readAsBytesSync(), old);
    });

    test('the stored hash differs from the header → the stored file is dropped', () async {
      final old = listBody(suffix: ['old.example.com']);
      final first = await refresher(
        () => old,
      ).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(old)));
      final fresh = listBody(suffix: ['new.example.com']);
      // Header names a third hash; the download is neither.
      final s = await refresher(() => fresh).refresh(
        profileId: 'p1',
        subscriptionUrl: sub,
        rawHeader: raw(header(fresh, sha: 'c' * 64)),
      );
      expect(s, isNull);
      expect(await store.current('p1'), isNull);
      // A running core may still use it: removed only after the next start.
      expect(File(first!.path).existsSync(), isTrue);
      await store.prune('p1');
      expect(File(first.path).existsSync(), isFalse);
    });

    test('a failed download keeps the stored file only if its hash matches the header', () async {
      final b = listBody();
      await refresher(() => b).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      final failing = RoutingListRefresher(
        store: store,
        download: (_, _, _) async => throw const SocketException('blocked'),
      );
      expect(await failing.refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b))), isNotNull);
      expect(
        await failing.refresh(
          profileId: 'p1',
          subscriptionUrl: sub,
          rawHeader: raw(header(b, sha: 'd' * 64)),
        ),
        isNull,
      );
      expect(await store.current('p1'), isNull);
    });

    test('no header, or a header for another host, drops the list without downloading', () async {
      final b = listBody();
      await refresher(() => b).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      final log = <Uri>[];
      expect(
        await refresher(() => b, log: log).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: null),
        isNull,
      );
      expect(await store.current('p1'), isNull);
      await refresher(() => b).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      final other = header(b, url: 'https://other.example.net/routing.json', sha: 'e' * 64);
      expect(
        await refresher(() => b, log: log).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(other)),
        isNull,
      );
      expect(log, isEmpty);
      expect(await store.current('p1'), isNull);
    });

    test('a mode change writes the other file and keeps the old one until the next start', () async {
      final w = listBody(suffix: ['w.example.com']);
      final s1 = await refresher(() => w).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(w)));
      final f = listBody(suffix: ['f.example.com']);
      final s2 = await refresher(() => f).refresh(
        profileId: 'p1',
        subscriptionUrl: sub,
        rawHeader: raw(header(f, mode: 'full')),
      );
      expect(s2!.mode, RoutingMode.full);
      expect(s2.path, isNot(s1!.path));
      // The running core (started in whitelist mode) still reads s1, and so do the options it
      // persisted for background starts.
      expect(File(s1.path).existsSync(), isTrue);
      expect(File(s1.path).readAsBytesSync(), w);
      // The next start keeps what it was started with and what is stored, and drops the rest.
      await store.prune('p1', keep: s1.path);
      expect(File(s1.path).existsSync(), isTrue);
      await store.prune('p1', keep: s2.path);
      expect(File(s1.path).existsSync(), isFalse);
      expect(File(s2.path).existsSync(), isTrue);
      expect((await store.current('p1'))?.path, s2.path);
    });

    test('a mode change while connected: the status line says it applies at the next connect', () async {
      final t = AppLocale.en.buildSync();
      final w = listBody(suffix: ['w.example.com']);
      await refresher(() => w).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(w)));
      final f = listBody(suffix: ['f.example.com']);
      final s2 = await refresher(() => f).refresh(
        profileId: 'p1',
        subscriptionUrl: sub,
        rawHeader: raw(header(f, mode: 'full')),
      );
      final running = RoutingStatus(s2, applied: const AppliedRouting('p1', RoutingMode.whitelist));
      expect(running.pending, isTrue);
      expect(routingStatusText(t, running), 'Full VPN: 2 services direct (applies at the next connect)');
      // After the next connect the core runs the stored mode: no note.
      expect(
        routingStatusText(t, RoutingStatus(s2, applied: const AppliedRouting('p1', RoutingMode.full))),
        'Full VPN: 2 services direct',
      );
      // Unknown (disconnected, or a start the app did not make): the stored list, no note.
      expect(routingStatusText(t, RoutingStatus(s2)), 'Full VPN: 2 services direct');
      // The list was dropped while a whitelist core runs.
      expect(
        routingStatusText(t, const RoutingStatus(null, applied: AppliedRouting('p1', RoutingMode.whitelist))),
        'Full VPN at the next connect',
      );
    });

    test('two refreshes of one profile at once run one after the other', () async {
      final a = listBody(suffix: ['a.example.com']);
      final b = listBody(suffix: ['b.example.com']);
      final gate = Completer<void>();
      final paths = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;
      final r = RoutingListRefresher(
        store: store,
        download: (url, path, maxBytes) async {
          paths.add(path);
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          final body = paths.length == 1 ? a : b;
          if (paths.length == 1) await gate.future;
          await File(path).writeAsBytes(body);
          inFlight--;
        },
      );
      final first = r.refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(a)));
      final second = r.refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      expect((await first)?.sha256, hex(a));
      expect((await second)?.sha256, hex(b));
      expect(maxInFlight, 1);
      expect(paths.toSet(), hasLength(2), reason: 'each download gets its own temporary file');
      expect((await store.current('p1'))?.sha256, hex(b));
      expect(dir.listSync().where((e) => e.path.endsWith('.tmp') || e.path.endsWith('.download')), isEmpty);
    });

    test('a stored file that was altered on disk is not used', () async {
      final b = listBody();
      final s = await refresher(() => b).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      File(s!.path).writeAsStringSync('{"version":3,"rules":[{"domain_suffix":["evil.example.com"]}]}');
      expect(await store.current('p1'), isNull);
    });

    test('clear drops the list and leaves the file for prune; remove deletes everything', () async {
      final b = listBody();
      await refresher(() => b).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      await store.clear('p1');
      expect(await store.current('p1'), isNull);
      expect(dir.listSync(), hasLength(1));
      await store.prune('p1');
      expect(dir.listSync(), isEmpty);
      await refresher(() => b).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      await store.remove('p1');
      expect(dir.listSync(), isEmpty);
    });

    test('noValidListFallsBackToFull', () async {
      final state = await store.current('p1');
      expect(state, isNull);
      final json = applyRoutingOptions(await baseOptions(), state).toJson();
      expect(json.containsKey('derbent-routing-mode'), isFalse);
      expect(json.containsKey('derbent-routing-rule-set'), isFalse);
      expect(routingStatusText(AppLocale.en.buildSync(), RoutingStatus(state)), isNull);
    });

    test('a valid list reaches the core options as mode + absolute path', () async {
      final b = listBody();
      final s = await refresher(() => b).refresh(profileId: 'p1', subscriptionUrl: sub, rawHeader: raw(header(b)));
      final json = applyRoutingOptions(await baseOptions(), s).toJson();
      expect(json['derbent-routing-mode'], 'whitelist');
      expect(json['derbent-routing-rule-set'], s!.path);
      expect(jsonDecode(jsonEncode(json))['derbent-routing-rule-set'], s.path);
    });
  });

  group('not overridable', () {
    test('a profile override cannot set the routing fields', () async {
      final opts = await baseOptions();
      final overridden = SingboxConfigOption.fromJson(
        ProfileParser.applyProfileOverride(
          opts.toJson(),
          jsonEncode({'derbent-routing-mode': 'full', 'derbent-routing-rule-set': '/tmp/x.json'}),
        ),
      );
      final json = applyRoutingOptions(overridden, null).toJson();
      expect(json.containsKey('derbent-routing-mode'), isFalse);
      expect(json.containsKey('derbent-routing-rule-set'), isFalse);
    });

    test('the header is stored with the profile but never becomes an override', () {
      const value =
          'mode=whitelist; url=$listUrl; sha256=0000000000000000000000000000000000000000000000000000000000000000';
      final headers = ProfileParser.mergeAndValidateHeaders({}, {'derbent-routing': value});
      expect(headers['derbent-routing'], value);
      final p = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: 'p1',
          active: true,
          name: '',
          url: sub.toString(),
          lastUpdate: DateTime.now(),
          populatedHeaders: headers,
        ),
      ).getOrElse((l) => throw l);
      expect(p.populatedHeaders?['derbent-routing'], value);
      expect(jsonDecode(p.profileOverride ?? '{}') as Map, isNot(contains('derbent-routing')));
    });
  });

  group('download through the subscription client', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('derbent_routing_dl_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    DioHttpClient client(List<String> log, Future<ResponseBody> Function(String, RequestOptions) behaviour) =>
        DioHttpClient(
          timeout: const Duration(seconds: 1),
          userAgent: 'test',
          debug: false,
          adapterFactory: (mode) => _FakeAdapter(mode, log, behaviour),
          tunnelUp: () async => true,
          retryDelayUnit: Duration.zero,
        );

    test('uses the one direct retry, and does not follow redirects', () async {
      final log = <String>[];
      final redirects = <bool>[];
      final c = client(log, (mode, o) async {
        redirects.add(o.followRedirects);
        if (mode == 'direct-once') return ResponseBody.fromString('{}', 200);
        throw DioException.connectionError(requestOptions: o, reason: 'tunnel dead');
      });
      await routingDownloadVia(c)(Uri.parse(listUrl), '${tmp.path}/r', RoutingListValidator.maxBytes);
      // The tunnel attempt keeps the subscription client's own retries; then exactly one direct attempt.
      expect(log.first, 'both');
      expect(log.where((m) => m == 'direct-once'), hasLength(1));
      expect(log.where((m) => m == 'direct'), isEmpty);
      expect(redirects, everyElement(isFalse));
    });

    test('a redirect is not followed: the download fails', () async {
      final log = <String>[];
      final uris = <Uri>[];
      final c = client(log, (mode, o) async {
        uris.add(o.uri);
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://evil.example.net/routing.json'],
          },
        );
      });
      await expectLater(
        routingDownloadVia(c)(Uri.parse(listUrl), '${tmp.path}/r', RoutingListValidator.maxBytes),
        throwsA(isA<DioException>()),
      );
      expect(uris, isNotEmpty);
      expect(uris, everyElement(Uri.parse(listUrl)));
      expect(File('${tmp.path}/r').existsSync() && File('${tmp.path}/r').lengthSync() > 0, isFalse);
    });

    test('a body over the cap is cut off and reported as too large', () async {
      final log = <String>[];
      final c = client(log, (mode, o) async => ResponseBody.fromBytes(Uint8List(300 * 1024), 200));
      await expectLater(
        routingDownloadVia(c)(Uri.parse(listUrl), '${tmp.path}/r', RoutingListValidator.maxBytes),
        throwsA(isA<RoutingDownloadTooLarge>()),
      );
      expect(log, ['both']);
    });
  });
}

// ignore: non_constant_identifier_names
bool p_isAbsolute(String path) => File(path).isAbsolute;

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.mode, this.log, this.behaviour);

  final String mode;
  final List<String> log;
  final Future<ResponseBody> Function(String mode, RequestOptions options) behaviour;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    log.add(mode);
    return behaviour(mode, options);
  }

  @override
  void close({bool force = false}) {}
}
