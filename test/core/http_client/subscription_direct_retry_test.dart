import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/app_update/data/app_update_repository.dart';

/// Records every request per client mode ("proxy", "both", "direct", "direct-once").
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

Future<ResponseBody> _networkErrorThroughTunnel(String mode, RequestOptions o) async {
  if (mode == 'direct-once' || mode == 'direct') return ResponseBody.fromString('vless://ok', 200);
  throw DioException.connectionError(requestOptions: o, reason: 'tunnel dead');
}

DioHttpClient _client(
  List<String> log,
  Future<ResponseBody> Function(String, RequestOptions) behaviour, {
  bool tunnelUp = true,
}) => DioHttpClient(
  timeout: const Duration(seconds: 1),
  userAgent: 'test',
  debug: false,
  adapterFactory: (mode) => _FakeAdapter(mode, log, behaviour),
  tunnelUp: () async => tunnelUp,
  retryDelayUnit: Duration.zero,
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('derbent_retry_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('subscription fetch through the tunnel fails with a network error → exactly one direct attempt', () async {
    final log = <String>[];
    final c = _client(log, _networkErrorThroughTunnel);
    final path = '${tmp.path}/sub';
    final rs = await c.download('https://sub.example.org/p/sub', path, directRetry: true);
    expect(rs.statusCode, 200);
    expect(File(path).readAsStringSync(), 'vless://ok');
    expect(log.where((m) => m == 'direct-once'), hasLength(1));
    expect(log.where((m) => m == 'direct'), isEmpty);
    expect(log.first, 'both');
  });

  test('timeouts and unknown errors through the tunnel also get the one direct attempt', () async {
    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.unknown,
    ]) {
      final log = <String>[];
      final c = _client(log, (mode, o) async {
        if (mode == 'direct-once') return ResponseBody.fromString('ok', 200);
        throw DioException(requestOptions: o, type: type);
      });
      await c.download('https://sub.example.org/p/sub', '${tmp.path}/sub', directRetry: true);
      expect(log.where((m) => m == 'direct-once'), hasLength(1), reason: '$type');
    }
  });

  test('the direct retry fails too → the error surfaces, still exactly one direct attempt', () async {
    final log = <String>[];
    final c = _client(log, (mode, o) async => throw DioException.connectionError(requestOptions: o, reason: 'x'));
    await expectLater(
      c.download('https://sub.example.org/p/sub', '${tmp.path}/sub', directRetry: true),
      throwsA(isA<DioException>()),
    );
    expect(log.where((m) => m == 'direct-once'), hasLength(1));
  });

  test('HTTP 4xx → no retry', () async {
    final log = <String>[];
    final c = _client(log, (mode, o) async => ResponseBody.fromString('nope', 404));
    await expectLater(
      c.download('https://sub.example.org/p/sub', '${tmp.path}/sub', directRetry: true),
      throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.badResponse)),
    );
    expect(log.where((m) => m.startsWith('direct')), isEmpty);
  });

  test('not connected (no tunnel) → no extra direct retry', () async {
    final log = <String>[];
    final c = _client(
      log,
      (mode, o) async => throw DioException.connectionError(requestOptions: o, reason: 'x'),
      tunnelUp: false,
    );
    await expectLater(
      c.download('https://sub.example.org/p/sub', '${tmp.path}/sub', directRetry: true),
      throwsA(isA<DioException>()),
    );
    expect(log.where((m) => m == 'direct-once'), isEmpty);
  });

  test('without directRetry a tunnel failure is not retried directly', () async {
    final log = <String>[];
    final c = _client(log, _networkErrorThroughTunnel);
    await expectLater(c.download('https://x.example.org/f', '${tmp.path}/f'), throwsA(isA<DioException>()));
    expect(log.where((m) => m.startsWith('direct')), isEmpty);
  });

  test('the app update check never takes the direct path', () async {
    final log = <String>[];
    final c = _client(log, _networkErrorThroughTunnel);
    final repo = AppUpdateRepositoryImpl(httpClient: c, proxyOnly: () => true);
    final result = await repo.getLatestVersion().run();
    expect(result.isLeft(), isTrue);
    expect(log, isNotEmpty);
    expect(log.every((m) => m == 'proxy'), isTrue, reason: 'got $log');
  });
}
