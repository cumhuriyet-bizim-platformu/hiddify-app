import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/app_update/data/app_update_repository.dart';

Map<String, dynamic> _release(String tag, {bool pre = false}) => {
  'tag_name': tag,
  'prerelease': pre,
  'published_at': '2026-10-01T00:00:00Z',
  'html_url': 'https://github.com/cumhuriyet-bizim-platformu/derbent-releases/releases/tag/$tag',
};

class _FakeHttpClient extends DioHttpClient {
  _FakeHttpClient(this.releases) : super(timeout: const Duration(seconds: 1), userAgent: 'test', debug: false);

  final List<Map<String, dynamic>> releases;
  final requestedUrls = <String>[];

  @override
  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
  }) async {
    requestedUrls.add(url);
    return Response<T>(data: releases as T, statusCode: 200, requestOptions: RequestOptions(path: url));
  }
}

void main() {
  test('picks the newest app release, skipping core-v and server-v releases', () async {
    final client = _FakeHttpClient([
      _release('core-v4.1.0-derbent.1'),
      _release('server-v11.0.0'),
      _release('v4.1.3.dev', pre: true),
      _release('v4.1.2'),
    ]);
    final result = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion().run();
    expect(result.getOrElse((_) => throw StateError('expected right'))?.version, '4.1.2');

    final withPre = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion(includePreReleases: true).run();
    expect(withPre.getOrElse((_) => throw StateError('expected right'))?.releaseTag, 'v4.1.3.dev');
  });

  test('requests 100 releases per page without altering the pinned base URL', () async {
    final client = _FakeHttpClient([_release('v4.1.2')]);
    await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion().run();
    expect(client.requestedUrls, ['${Constants.githubReleasesApiUrl}?per_page=100']);
  });

  test('no app release in the response yields not-available (null), not an error', () async {
    final client = _FakeHttpClient([_release('core-v4.1.0-derbent.1'), _release('server-v11.0.0')]);
    final result = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion().run();
    expect(result.isRight(), isTrue);
    expect(result.getOrElse((_) => throw StateError('expected right')), isNull);
  });
}
