import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/app_update/data/app_update_repository.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';

Map<String, dynamic> _release(String tag, {bool pre = false}) => {
  'tag_name': tag,
  'prerelease': pre,
  'published_at': '2026-10-01T00:00:00Z',
  'html_url': 'https://github.com/cumhuriyet-bizim-platformu/derbent-releases/releases/tag/$tag',
};

class _FakeHttpClient extends DioHttpClient {
  _FakeHttpClient(List<Map<String, dynamic>> releases) : this.pages([releases]);
  _FakeHttpClient.pages(this.pages, {this.statusByPage = const {}, this.throwOnPage})
    : super(timeout: const Duration(seconds: 1), userAgent: 'test', debug: false);

  /// Page N (1-based) returns pages[N-1]; past the end returns an empty list.
  final List<List<Map<String, dynamic>>> pages;
  final Map<int, int> statusByPage;
  final int? throwOnPage;
  final requestedUrls = <String>[];
  final proxyOnlyFlags = <bool>[];

  @override
  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
  }) async {
    requestedUrls.add(url);
    proxyOnlyFlags.add(proxyOnly);
    final page = int.tryParse(Uri.parse(url).queryParameters['page'] ?? '1') ?? 1;
    final opts = RequestOptions(path: url);
    if (page == throwOnPage) throw DioException(requestOptions: opts, type: DioExceptionType.connectionError);
    final data = page <= pages.length ? pages[page - 1] : <Map<String, dynamic>>[];
    return Response<T>(data: data as T, statusCode: statusByPage[page] ?? 200, requestOptions: opts);
  }
}

AppUpdateRepositoryImpl _repo(_FakeHttpClient c, {bool connected = false}) =>
    AppUpdateRepositoryImpl(httpClient: c, proxyOnly: () => connected);

void main() {
  test('picks the newest app release, skipping core-v and server-v releases', () async {
    final client = _FakeHttpClient([
      _release('core-v4.1.0-derbent.1'),
      _release('server-v11.0.0'),
      _release('v4.1.3-derbent.1.dev', pre: true),
      _release('v4.1.2-derbent.1'),
    ]);
    final result = await _repo(client).getLatestVersion().run();
    expect(result.getOrElse((_) => throw StateError('expected right'))?.version, '4.1.2');

    final withPre = await _repo(client).getLatestVersion(includePreReleases: true).run();
    expect(withPre.getOrElse((_) => throw StateError('expected right'))?.releaseTag, 'v4.1.3-derbent.1.dev');
  });

  test('requests 100 releases per page without altering the pinned base URL', () async {
    final client = _FakeHttpClient([_release('v4.1.2-derbent.1')]);
    await _repo(client).getLatestVersion().run();
    expect(client.requestedUrls, ['${Constants.githubReleasesApiUrl}?per_page=100&page=1']);
  });

  test('no app release in the response yields not-available (null), not an error', () async {
    final client = _FakeHttpClient([_release('core-v4.1.0-derbent.1'), _release('server-v11.0.0')]);
    final result = await _repo(client).getLatestVersion().run();
    expect(result.isRight(), isTrue);
    expect(result.getOrElse((_) => throw StateError('expected right')), isNull);
  });

  group('proxy-only while connected', () {
    test('connected: every request uses proxyOnly', () async {
      final c = _FakeHttpClient.pages([
        [for (var i = 0; i < 100; i++) _release('core-v4.1.$i-derbent.1')],
        [_release('v4.1.2-derbent.1')],
      ]);
      await _repo(c, connected: true).getLatestVersion().run();
      expect(c.proxyOnlyFlags, [true, true]);
    });

    test('disconnected: direct requests stay allowed', () async {
      final c = _FakeHttpClient([_release('v4.1.2-derbent.1')]);
      await _repo(c).getLatestVersion().run();
      expect(c.proxyOnlyFlags, [false]);
    });

    test('connected: the 5-request cap is proxy-only on every request', () async {
      final page = [for (var i = 0; i < 100; i++) _release('core-v4.1.$i-derbent.1')];
      final c = _FakeHttpClient.pages([page, page, page, page, page, page, page]);
      await _repo(c, connected: true).getLatestVersion().run();
      expect(c.proxyOnlyFlags, [true, true, true, true, true]);
    });

    test('connected and proxy fails: AppUpdateFailure, no direct retry', () async {
      final c = _FakeHttpClient.pages([[]], throwOnPage: 1);
      final r = await _repo(c, connected: true).getLatestVersion().run();
      expect(r.isLeft(), isTrue);
      expect(c.requestedUrls.length, 1);
      expect(c.proxyOnlyFlags, [true]);
    });
  });

  group('paging', () {
    test('release on page 2 behind 100 core-v releases is found', () async {
      final c = _FakeHttpClient.pages([
        [for (var i = 0; i < 100; i++) _release('core-v4.1.$i-derbent.1')],
        [_release('v4.1.2-derbent.1')],
      ]);
      final r = await _repo(c).getLatestVersion().run();
      expect(r.getOrElse((_) => throw StateError('left'))?.releaseTag, 'v4.1.2-derbent.1');
      expect(c.requestedUrls.last, endsWith('?per_page=100&page=2'));
    });

    test('an empty page ends the loop: no update', () async {
      final c = _FakeHttpClient.pages([
        [for (var i = 0; i < 100; i++) _release('core-v4.1.$i-derbent.1')],
        [],
      ]);
      final r = await _repo(c).getLatestVersion().run();
      expect(r.getOrElse((_) => throw StateError('left')), isNull);
      expect(c.requestedUrls.length, 2);
    });

    test('non-200 on page 2 is AppUpdateFailure', () async {
      final c = _FakeHttpClient.pages(
        [
          [for (var i = 0; i < 100; i++) _release('core-v4.1.$i-derbent.1')],
          [_release('v4.1.2-derbent.1')],
        ],
        statusByPage: {2: 403},
      );
      final r = await _repo(c).getLatestVersion().run();
      expect(r.isLeft(), isTrue);
      expect(r.swap().getOrElse((_) => throw StateError('right')), const AppUpdateFailure.unexpected());
    });

    test('pages with no app release stop at 5 requests', () async {
      final page = [for (var i = 0; i < 100; i++) _release('core-v4.1.$i-derbent.1')];
      final c = _FakeHttpClient.pages([page, page, page, page, page, page, page]);
      final r = await _repo(c).getLatestVersion().run();
      expect(r.getOrElse((_) => throw StateError('left')), isNull);
      expect(c.requestedUrls.length, 5);
    });

    test('a short page (under 100) ends the loop without another request', () async {
      final c = _FakeHttpClient.pages([
        [_release('core-v4.1.0-derbent.1')],
        [_release('v4.1.2-derbent.1')],
      ]);
      final r = await _repo(c).getLatestVersion().run();
      expect(r.getOrElse((_) => throw StateError('left')), isNull);
      expect(c.requestedUrls.length, 1);
    });

    test('stable-only skips a pre-release on page 1 and finds the stable on page 2', () async {
      final c = _FakeHttpClient.pages([
        [for (var i = 0; i < 99; i++) _release('core-v4.1.$i-derbent.1'), _release('v4.1.3-derbent.1', pre: true)],
        [_release('v4.1.2-derbent.1')],
      ]);
      final r = await _repo(c).getLatestVersion().run();
      expect(r.getOrElse((_) => throw StateError('left'))?.releaseTag, 'v4.1.2-derbent.1');
    });
  });

  group('version scheme', () {
    test('v4.1.2-derbent.1 is an app release; core-v4.1.0-derbent.1 is not', () {
      expect(GithubReleaseParser.isAppRelease(_release('v4.1.2-derbent.1')), isTrue);
      expect(GithubReleaseParser.isAppRelease(_release('core-v4.1.0-derbent.1')), isFalse);
    });
  });
}
