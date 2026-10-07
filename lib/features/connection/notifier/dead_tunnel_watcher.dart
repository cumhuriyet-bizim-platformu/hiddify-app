import 'dart:async';

import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Derbent (phase A, A3): while connected, watch the core's per-outbound health. When every outbound
/// has failed its latest test, force-update the active subscription and reconnect only if the stored
/// config content changed (the operator may have moved the servers to new, unblocked addresses).
///
/// Loop safety (a normal reconnect or a network change makes every outbound fail for a moment):
/// - nothing happens in the first [connectGrace] after connecting;
/// - [onAllDead] runs at most once per [minInterval], and that limit survives reconnects because this
///   watcher lives for the whole app session (one instance per provider), not per connection;
/// - [onAllDead] never overlaps with itself.
class DeadTunnelWatcher with InfraLogger {
  DeadTunnelWatcher({
    required this.watchGroup,
    required this.onAllDead,
    DateTime Function()? now,
    this.connectGrace = const Duration(seconds: 60),
    this.minInterval = const Duration(minutes: 5),
    this.resubscribeDelay = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now;

  /// The group stream the proxies page uses (the core's `OutboundsInfo`, first group).
  final Stream<OutboundGroup?> Function() watchGroup;
  final Future<void> Function() onAllDead;
  final Duration connectGrace;
  final Duration minInterval;
  final Duration resubscribeDelay;
  final DateTime Function() _now;

  /// sing-box `monitoring.TimeoutDelay` is 65535: a URL test that errored or timed out. The UI uses the
  /// same `> 65000` threshold to show "timeout"/"×" (active_proxy_delay_indicator.dart, proxy_tile.dart).
  static const failedDelayThreshold = 65000;

  /// "Every outbound failed": the group has at least one leaf outbound (not a selector/balancer item,
  /// whose own delay only mirrors its members), and every leaf's latest URL-test delay is a failure
  /// (> [failedDelayThreshold]). A delay of 0 means untested (or a cached result the core hides), and
  /// counts as "not failed": the watcher only acts on completed, failed tests.
  static bool allOutboundsFailed(OutboundGroup? group) {
    if (group == null) return false;
    final leaves = group.items.where((o) => !o.isGroup).toList();
    if (leaves.isEmpty) return false;
    return leaves.every((o) => o.urlTestDelay > failedDelayThreshold);
  }

  StreamSubscription<OutboundGroup?>? _sub;
  Timer? _resubscribe;
  DateTime? _connectedAt;
  DateTime? _lastRun;
  bool _running = false;

  bool get _connected => _connectedAt != null;

  void onConnected() {
    _connectedAt = _now();
    _subscribe();
  }

  void onDisconnected() {
    _connectedAt = null;
    _cancel();
  }

  Future<void> dispose() async {
    _connectedAt = null;
    _cancel();
  }

  void _cancel() {
    _resubscribe?.cancel();
    _resubscribe = null;
    _sub?.cancel();
    _sub = null;
  }

  void _subscribe() {
    _cancel();
    _sub = watchGroup().listen(
      _onGroup,
      onError: (Object e) => loggy.debug("outbound group stream error: $e"),
      // The core's stream can end (core restart). Re-watch while still connected.
      onDone: () {
        _sub = null;
        if (_connected) _resubscribe = Timer(resubscribeDelay, () => _connected ? _subscribe() : null);
      },
    );
  }

  Future<void> _onGroup(OutboundGroup? group) async {
    if (!_connected || _running) return;
    if (!allOutboundsFailed(group)) return;
    final now = _now();
    if (now.difference(_connectedAt!) < connectGrace) return;
    if (_lastRun != null && now.difference(_lastRun!) < minInterval) return;
    _lastRun = now;
    _running = true;
    try {
      loggy.warning("every outbound failed its latest test; refreshing the active subscription");
      await onAllDead();
    } catch (e, st) {
      loggy.warning("dead-tunnel refresh failed", e, st);
    } finally {
      _running = false;
    }
  }
}

/// Force-updates the active profile and reconnects only if its stored config content changed.
/// Returns whether it reconnected.
Future<bool> refreshAndReconnectIfChanged({
  required Future<String?> Function() readStoredConfig,
  required Future<bool> Function() forceUpdate,
  required Future<void> Function() reconnect,
}) async {
  final before = await readStoredConfig();
  if (!await forceUpdate()) return false;
  final after = await readStoredConfig();
  if (after == null || after == before) return false;
  await reconnect();
  return true;
}

/// Lives for the app session (listened from ConnectionWrapper); starts/stops watching with the
/// connection status.
final deadTunnelWatcherProvider = Provider<DeadTunnelWatcher>((ref) {
  final watcher = DeadTunnelWatcher(
    watchGroup: () => ref.read(proxyRepositoryProvider).watchProxies().map((e) => e.getOrElse((_) => null)),
    onAllDead: () async {
      final profile = await ref.read(activeProfileProvider.future);
      // Only a remote (subscription) profile can be refreshed.
      if (profile is! RemoteProfileEntity) return;
      final repo = await ref.read(profileRepositoryProvider.future);
      await refreshAndReconnectIfChanged(
        // The stored config file of the profile (what the core runs), read before and after the update.
        readStoredConfig: () => repo.getRawConfig(profile.id).match((_) => null, (c) => c).run(),
        // The same forced update as the profile tile's "update" action.
        forceUpdate: () => repo.upsertRemote(profile.url).match((_) => false, (_) => true).run(),
        reconnect: () async =>
            ref.read(connectionNotifierProvider.notifier).reconnect(await ref.read(activeProfileProvider.future)),
      );
    },
  );
  ref.listen<AsyncValue<ConnectionStatus>>(connectionNotifierProvider, (previous, next) {
    final wasConnected = previous?.valueOrNull?.isConnected ?? false;
    final isConnected = next.valueOrNull?.isConnected ?? false;
    if (isConnected && !wasConnected) {
      watcher.onConnected();
    } else if (!isConnected && wasConnected) {
      watcher.onDisconnected();
    }
  }, fireImmediately: true);
  ref.onDispose(watcher.dispose);
  return watcher;
});
