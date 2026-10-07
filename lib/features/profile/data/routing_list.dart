// Derbent: the panel's routing list (whitelist mode and the full-VPN bypass list).
//
// Threat model: the SERVER enforces whitelist mode. A whitelisted user's traffic to an unlisted
// destination is refused by the server whatever this app does, so this list only decides which
// traffic the app sends direct (fast, and keeps load off the servers) instead of into a tunnel
// that would refuse it. A missing, stale or tampered list must therefore never widen what goes
// direct: every failure here falls back to the full VPN (no routing fields for the core), and the
// list is accepted only from the subscription's own host, over https with normal certificate
// checks, pinned by the sha256 the panel sends in the `derbent-routing` subscription header.
// The core validates the file again before using it (hiddify-core rule_set_local.go).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:path/path.dart' as p;

enum RoutingMode { whitelist, full }

/// `derbent-routing: mode=<whitelist|full>; url=<https url>; sha256=<hex>`
class RoutingHeader {
  const RoutingHeader({required this.mode, required this.url, required this.sha256});

  final RoutingMode mode;
  final Uri url;

  /// Lower-case hex, 64 chars.
  final String sha256;

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// Lenient: `;`-separated `k=v`, trimmed, any order, unknown keys ignored. Null when a field is
  /// missing or malformed.
  static RoutingHeader? parse(String raw) {
    final fields = <String, String>{};
    for (final part in raw.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      fields[part.substring(0, i).trim().toLowerCase()] = part.substring(i + 1).trim();
    }
    final mode = RoutingMode.values.where((m) => m.name == fields['mode']?.toLowerCase()).firstOrNull;
    final url = Uri.tryParse(fields['url'] ?? '');
    final sha = fields['sha256']?.toLowerCase();
    if (mode == null || url == null || !url.isAbsolute || url.host.isEmpty || sha == null || !_hex64.hasMatch(sha)) {
      return null;
    }
    return RoutingHeader(mode: mode, url: url, sha256: sha);
  }

  @override
  String toString() => 'mode=${mode.name}; url=$url; sha256=$sha256';
}

enum RoutingRejection {
  scheme,
  host,
  tooLarge,
  hash,
  format,
  key,
  version,
  empty,
  tooManyEntries,
  hostname,
  cidr,
  download,
}

sealed class RoutingValidation {
  const RoutingValidation();
}

class RoutingOk extends RoutingValidation {
  const RoutingOk(this.count);
  final int count;
}

class RoutingRejected extends RoutingValidation {
  const RoutingRejected(this.reason, [this.detail = '']);
  final RoutingRejection reason;
  final String detail;

  @override
  String toString() => 'rejected (${reason.name})${detail.isEmpty ? '' : ': $detail'}';
}

abstract final class RoutingListValidator {
  static const maxBytes = 256 * 1024;
  static const maxEntries = 2000;
  static const allowedKeys = {'domain', 'domain_suffix', 'ip_cidr'};

  // Same rule as the panel (hutils/routing/lists.py): lower-case labels of [a-z0-9-]{1,63} not
  // starting or ending with "-", at least two labels, at most 253 chars, no all-digit TLD.
  static final _label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  static final _prefix = RegExp(r'^[0-9]{1,3}$');

  /// The URL checks alone: https, and the subscription's own host.
  static RoutingRejected? checkUrl(RoutingHeader h, Uri subscriptionUrl) {
    if (h.url.scheme.toLowerCase() != 'https') return RoutingRejected(RoutingRejection.scheme, h.url.scheme);
    if (h.url.host.toLowerCase() != subscriptionUrl.host.toLowerCase()) {
      return RoutingRejected(RoutingRejection.host, '${h.url.host} != ${subscriptionUrl.host}');
    }
    return null;
  }

  static RoutingValidation validate(Uint8List body, RoutingHeader h, Uri subscriptionUrl) {
    if (checkUrl(h, subscriptionUrl) case final rejected?) return rejected;
    if (body.length > maxBytes) return RoutingRejected(RoutingRejection.tooLarge, '${body.length} bytes');
    if (crypto.sha256.convert(body).toString() != h.sha256) return const RoutingRejected(RoutingRejection.hash);

    final Object? doc;
    try {
      doc = jsonDecode(utf8.decode(body));
    } catch (e) {
      return RoutingRejected(RoutingRejection.format, '$e');
    }
    if (doc is! Map<String, dynamic>) return const RoutingRejected(RoutingRejection.format, 'not an object');
    if (doc.keys.any((k) => k != 'version' && k != 'rules')) {
      return RoutingRejected(RoutingRejection.key, doc.keys.join(','));
    }
    if (doc['version'] != 3) return RoutingRejected(RoutingRejection.version, '${doc['version']}');
    final rules = doc['rules'];
    if (rules is! List) return const RoutingRejected(RoutingRejection.format, 'rules');
    if (rules.isEmpty) return const RoutingRejected(RoutingRejection.empty, 'no rules');

    final hosts = <String>[];
    final cidrs = <String>[];
    for (final rule in rules) {
      if (rule is! Map<String, dynamic>) return const RoutingRejected(RoutingRejection.format, 'rule');
      if (rule.keys.firstWhereOrNull((k) => !allowedKeys.contains(k)) case final k?) {
        return RoutingRejected(RoutingRejection.key, k);
      }
      var inRule = 0;
      for (final MapEntry(:key, :value) in rule.entries) {
        if (value is! List || value.any((v) => v is! String)) {
          return RoutingRejected(RoutingRejection.format, '$key is not a list of strings');
        }
        (key == 'ip_cidr' ? cidrs : hosts).addAll(value.cast<String>());
        inRule += value.length;
      }
      // A rule without any entry would match every destination in sing-box.
      if (inRule == 0) return const RoutingRejected(RoutingRejection.empty, 'empty rule');
      if (hosts.length + cidrs.length > maxEntries) break;
    }
    final count = hosts.length + cidrs.length;
    if (count > maxEntries) return const RoutingRejected(RoutingRejection.tooManyEntries, '> $maxEntries');

    if (hosts.firstWhereOrNull((h) => !isHostname(h)) case final bad?) {
      return RoutingRejected(RoutingRejection.hostname, bad);
    }
    if (cidrs.firstWhereOrNull((c) => !isCidr(c)) case final bad?) return RoutingRejected(RoutingRejection.cidr, bad);
    return RoutingOk(count);
  }

  static bool isHostname(String s) {
    if (s.isEmpty || s.length > 253) return false;
    final labels = s.split('.');
    if (labels.length < 2 || !labels.every(_label.hasMatch)) return false;
    return !RegExp(r'^[0-9]+$').hasMatch(labels.last);
  }

  static bool isCidr(String s) {
    final parts = s.split('/');
    if (parts.length != 2 || !_prefix.hasMatch(parts[1]) || parts[0].contains('%')) return false;
    final addr = InternetAddress.tryParse(parts[0]);
    if (addr == null) return false;
    final prefix = int.parse(parts[1]);
    return prefix <= (addr.type == InternetAddressType.IPv4 ? 32 : 128);
  }
}

class RoutingListState {
  const RoutingListState({required this.mode, required this.count, required this.sha256, required this.path});

  final RoutingMode mode;
  final int count;
  final String sha256;

  /// Absolute path of the stored rule-set file, handed to the core.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is RoutingListState &&
      other.mode == mode &&
      other.count == count &&
      other.sha256 == sha256 &&
      other.path == path;

  @override
  int get hashCode => Object.hash(mode, count, sha256, path);
}

/// Stores the validated list next to the profile's config, in the profile directory:
/// `<id>.routing-<mode>.json` (the rule-set the core reads) and `<id>.routing.meta.json`.
///
/// One file name per mode: the core reloads a local rule-set when its file changes, so a new list
/// of the same mode takes effect live, while a list of the other mode never lands in the file a
/// running core (built for the old mode) is watching; that one is removed and the new mode applies
/// at the next connect. The stored config file (`<id>.json`) is untouched, so the dead-tunnel
/// watcher's "content changed" comparison never sees the list.
class RoutingListStore {
  RoutingListStore(Directory dir) : _dir = dir.absolute;

  final Directory _dir;

  String pathFor(String profileId, RoutingMode mode) => p.join(_dir.path, '$profileId.routing-${mode.name}.json');

  File _meta(String profileId) => File(p.join(_dir.path, '$profileId.routing.meta.json'));

  File downloadFile(String profileId) => File(p.join(_dir.path, '$profileId.routing.download'));

  Future<RoutingListState> save(
    String profileId,
    Uint8List body, {
    required RoutingMode mode,
    required int count,
  }) async {
    await _dir.create(recursive: true);
    final state = RoutingListState(
      mode: mode,
      count: count,
      sha256: crypto.sha256.convert(body).toString(),
      path: pathFor(profileId, mode),
    );
    await _writeAtomic(File(state.path), body);
    for (final other in RoutingMode.values.where((m) => m != mode)) {
      await _deleteIfExists(File(pathFor(profileId, other)));
    }
    await _writeAtomic(
      _meta(profileId),
      utf8.encode(jsonEncode({'mode': mode.name, 'count': count, 'sha256': state.sha256})),
    );
    return state;
  }

  /// The stored list, or null when there is none or it no longer matches what was validated.
  Future<RoutingListState?> current(String profileId) async {
    try {
      final meta = _meta(profileId);
      if (!await meta.exists()) return null;
      final m = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      final mode = RoutingMode.values.byName(m['mode'] as String);
      final count = m['count'] as int;
      final sha = m['sha256'] as String;
      final file = File(pathFor(profileId, mode));
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length > RoutingListValidator.maxBytes || crypto.sha256.convert(bytes).toString() != sha) return null;
      return RoutingListState(mode: mode, count: count, sha256: sha, path: file.path);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String profileId) async {
    await _deleteIfExists(_meta(profileId));
    for (final mode in RoutingMode.values) {
      await _deleteIfExists(File(pathFor(profileId, mode)));
    }
    await _deleteIfExists(downloadFile(profileId));
  }

  static Future<void> _writeAtomic(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> _deleteIfExists(File f) async {
    if (await f.exists()) await f.delete();
  }
}

/// Downloads [url] into [path]; throws on any failure, [RoutingDownloadTooLarge] past [maxBytes].
typedef RoutingDownload = Future<void> Function(Uri url, String path, int maxBytes);

class RoutingDownloadTooLarge implements Exception {
  @override
  String toString() => 'routing list larger than ${RoutingListValidator.maxBytes} bytes';
}

/// The subscription's own client and retry (one direct retry through a dead tunnel, Task 4), normal
/// certificate checks (no insecure option exists on this client), no redirects (the host must stay
/// the subscription host), and the size cap enforced while receiving.
RoutingDownload routingDownloadVia(DioHttpClient client) => (url, path, maxBytes) async {
  final token = CancelToken();
  var tooLarge = false;
  try {
    await client.download(
      url.toString(),
      path,
      cancelToken: token,
      directRetry: true,
      followRedirects: false,
      onReceiveProgress: (received, total) {
        if (!tooLarge && (received > maxBytes || total > maxBytes)) {
          tooLarge = true;
          token.cancel('routing list over $maxBytes bytes');
        }
      },
    );
  } on DioException {
    if (tooLarge) throw RoutingDownloadTooLarge();
    rethrow;
  }
  if (tooLarge) throw RoutingDownloadTooLarge();
};

class RoutingListRefresher with InfraLogger {
  RoutingListRefresher({required this.store, required RoutingDownload download}) : _download = download;

  final RoutingListStore store;
  final RoutingDownload _download;

  /// Runs after every successful subscription refresh. Returns the list now in effect, or null
  /// (full VPN). Never throws for a bad list.
  Future<RoutingListState?> refresh({
    required String profileId,
    required Uri subscriptionUrl,
    required String? rawHeader,
  }) async {
    final header = rawHeader == null ? null : RoutingHeader.parse(rawHeader);
    if (header == null) {
      if (rawHeader != null) loggy.warning('derbent-routing header unreadable; full VPN');
      await store.clear(profileId);
      return null;
    }
    if (RoutingListValidator.checkUrl(header, subscriptionUrl) case final rejected?) {
      return _fallback(profileId, header, rejected);
    }

    final tmp = store.downloadFile(profileId);
    try {
      await tmp.parent.create(recursive: true);
      await _download(header.url, tmp.path, RoutingListValidator.maxBytes);
      if (await tmp.length() > RoutingListValidator.maxBytes) {
        return _fallback(profileId, header, const RoutingRejected(RoutingRejection.tooLarge));
      }
      final body = await tmp.readAsBytes();
      switch (RoutingListValidator.validate(body, header, subscriptionUrl)) {
        case RoutingOk(:final count):
          final state = await store.save(profileId, body, mode: header.mode, count: count);
          loggy.info('routing list stored: ${header.mode.name}, $count entries');
          return state;
        case final RoutingRejected rejected:
          return _fallback(profileId, header, rejected);
      }
    } on RoutingDownloadTooLarge {
      return _fallback(profileId, header, const RoutingRejected(RoutingRejection.tooLarge));
    } catch (e) {
      return _fallback(profileId, header, RoutingRejected(RoutingRejection.download, '$e'));
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// Keep the previous valid file only if its hash still matches the current header (for example a
  /// cache served an old subscription while the file is already new); otherwise drop it.
  Future<RoutingListState?> _fallback(String profileId, RoutingHeader header, RoutingRejected why) async {
    final previous = await store.current(profileId);
    if (previous != null && previous.sha256 == header.sha256) {
      loggy.warning('routing list $why; keeping the previous list (hash still matches)');
      if (previous.mode == header.mode) return previous;
      return store.save(profileId, await File(previous.path).readAsBytes(), mode: header.mode, count: previous.count);
    }
    loggy.warning('routing list $why; no valid list, full VPN');
    await store.clear(profileId);
    return null;
  }
}

/// Sets the core's routing fields from the validated list, and only from it: called after the
/// profile override has been applied, so an override can never set them. No list → both null →
/// omitted from the JSON → the core keeps today's full-VPN routing.
SingboxConfigOption applyRoutingOptions(SingboxConfigOption options, RoutingListState? state) =>
    options.copyWith(derbentRoutingMode: state?.mode.name, derbentRoutingRuleSet: state?.path);

extension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
