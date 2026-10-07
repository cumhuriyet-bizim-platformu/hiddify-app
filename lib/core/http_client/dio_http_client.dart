import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';

import 'package:hiddify/utils/custom_loggers.dart';
import 'package:meta/meta.dart';

class DioHttpClient with InfraLogger {
  final Map<String, Dio> _dio = {};
  DioHttpClient({
    required Duration timeout,
    required this.userAgent,
    required bool debug,
    @visibleForTesting HttpClientAdapter Function(String mode)? adapterFactory,
    @visibleForTesting Future<bool> Function()? tunnelUp,
    @visibleForTesting Duration retryDelayUnit = const Duration(seconds: 1),
  }) : _tunnelUp = tunnelUp {
    // Derbent: "direct-once" is the single direct retry for subscription fetches (see download). It has
    // no retry interceptor, so the ISP sees exactly one extra direct request, never a burst.
    for (final mode in ["proxy", "direct", "both", "direct-once"]) {
      _dio[mode] = Dio(
        BaseOptions(
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          headers: {"User-Agent": userAgent},
        ),
      );
      if (mode != "direct-once") {
        _dio[mode]!.interceptors.add(
          RetryInterceptor(
            dio: _dio[mode]!,
            retryDelays: [
              retryDelayUnit,
              if (mode != "proxy") ...[retryDelayUnit * 2, retryDelayUnit * 3],
            ],
          ),
        );
      }

      _dio[mode]!.httpClientAdapter =
          adapterFactory?.call(mode) ??
          IOHttpClientAdapter(
            createHttpClient: () {
              final client = HttpClient();
              client.findProxy = (url) {
                if (mode == "proxy") {
                  return "PROXY localhost:$port";
                } else if (mode == "direct" || mode == "direct-once") {
                  return "DIRECT";
                } else {
                  return "PROXY localhost:$port; DIRECT";
                }
              };
              return client;
            },
          );
    }

    if (debug) {
      // _dio.interceptors.add(LoggyDioInterceptor(requestHeader: true));
    }
  }

  final Future<bool> Function()? _tunnelUp;

  Future<String> _mode(bool proxyOnly) async => proxyOnly
      ? "proxy"
      : await (_tunnelUp?.call() ?? isPortOpen("127.0.0.1", port))
      ? "both"
      : "direct";

  /// Network-level failures that a direct attempt might get past. Not HTTP errors (4xx/5xx: the server
  /// answered), not cancellation, and not certificate errors (never retry a TLS failure outside the tunnel).
  @visibleForTesting
  static bool isNetworkError(Object err) =>
      err is DioException &&
      switch (err.type) {
        DioExceptionType.connectionError ||
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.unknown => true,
        _ => false,
      };

  int port = 0;

  String userAgent;
  // bool isPortOpen(String host, int port, {Duration timeout = const Duration(milliseconds: 200)}) async{
  //   try {
  //     Socket.connect(host, port, timeout: timeout).then((socket) {
  //       socket.destroy();
  //     });
  //     return true;
  //   } on SocketException catch (_) {
  //     return false;
  //   } catch (_) {
  //     return false;
  //   }
  // }
  Future<bool> isPortOpen(String host, int port, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      await socket.close();
      return true;
    } on SocketException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }

  void setProxyPort(int port) {
    this.port = port;
    loggy.debug("setting proxy port: [$port]");
  }

  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
  }) async {
    final mode = await _mode(proxyOnly);
    final dio = _dio[mode]!;

    return dio.get<T>(
      url,
      cancelToken: cancelToken,
      options: _options(url, userAgent: userAgent, credentials: credentials),
    );
  }

  /// [directRetry]: subscription fetches only. Never set it for the app update check, which stays
  /// proxy-only (it calls [get] with `proxyOnly`), nor together with [proxyOnly].
  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
    bool directRetry = false,
  }) async {
    assert(!(proxyOnly && directRetry), "a proxy-only request must never be retried directly");
    final mode = await _mode(proxyOnly);
    final options = _options(url, userAgent: userAgent, credentials: credentials);
    try {
      return await _dio[mode]!.download(url, path, cancelToken: cancelToken, options: options);
    } catch (err) {
      // Derbent: one direct retry for a subscription fetch that failed with a network error while the
      // tunnel is up (every server may be blocked, and the new server list is exactly what we need).
      // The subscription host is the operator's own, ideally the Cloudflare-fronted (orange)
      // sub_link_only domain, so the ISP sees only that hostname over TLS.
      if (!directRetry || proxyOnly || mode == "direct" || !isNetworkError(err)) rethrow;
      loggy.warning("subscription fetch through the tunnel failed (${(err as DioException).type}), one direct retry");
      return _dio["direct-once"]!.download(url, path, cancelToken: cancelToken, options: options);
    }
  }

  Options _options(String url, {String? userAgent, ({String username, String password})? credentials}) {
    final uri = Uri.parse(url);

    String? userInfo;
    if (credentials != null) {
      userInfo = "${credentials.username}:${credentials.password}";
    } else if (uri.userInfo.isNotEmpty) {
      userInfo = uri.userInfo;
    }

    String? basicAuth;
    if (userInfo != null) {
      basicAuth = "Basic ${base64.encode(utf8.encode(userInfo))}";
    }

    return Options(
      headers: {
        if (userAgent != null) "User-Agent": userAgent,
        if (basicAuth != null) "authorization": basicAuth,
        // "Accept": "application/json",
        // "Content-Type": "application/json",
      },
    );
  }
}
