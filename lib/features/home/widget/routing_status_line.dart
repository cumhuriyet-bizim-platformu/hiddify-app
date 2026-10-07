import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/routing_list.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// What the status line shows: the list stored for the active profile, and, while connected, the
/// mode the running core was started with when the app knows it.
class RoutingStatus {
  const RoutingStatus(this.stored, {this.applied});

  /// The validated list on disk, or null (the next connect is full VPN).
  final RoutingListState? stored;

  /// Null when unknown (disconnected, or a start the app did not make). Otherwise the mode the
  /// running core uses, `mode: null` meaning full VPN without a list.
  final AppliedRouting? applied;

  /// The stored list differs from what the running core uses: it applies at the next connect.
  bool get pending => applied != null && applied!.mode != stored?.mode;
}

/// Derbent: the routing list stored for the active profile (re-read whenever the active profile row
/// changes; the list is refreshed before a subscription update is written to the database, so the
/// new row already sees the new list), and the mode the running core was started with.
final routingStatusProvider = FutureProvider<RoutingStatus>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return const RoutingStatus(null);
  final stored = await ref.watch(routingListStoreProvider).current(profile.id);
  final applied = ref.watch(appliedRoutingProvider);
  final connected = await ref.watch(serviceRunningProvider.future);
  return RoutingStatus(stored, applied: connected && applied?.profileId == profile.id ? applied : null);
});

/// Null when there is no valid list and nothing pending: nothing is shown, never "whitelist active".
String? routingStatusText(Translations t, RoutingStatus status) {
  final r = t.pages.home.routing;
  final text = switch (status.stored) {
    null => null,
    RoutingListState(mode: RoutingMode.whitelist, :final count) => r.whitelist(n: count),
    RoutingListState(mode: RoutingMode.full, :final count) => r.full(n: count),
  };
  if (!status.pending) return text;
  return text == null ? r.fullNextConnect : r.nextConnect(text: text);
}

/// Derbent: read-only status of the panel's routing mode. The mode is set per user on the panel and
/// cannot be changed in the app.
class RoutingStatusLine extends HookConsumerWidget {
  const RoutingStatusLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final status = ref.watch(routingStatusProvider).valueOrNull;
    final text = status == null ? null : routingStatusText(t, status);
    if (text == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        text,
        key: const ValueKey('derbent_routing_status'),
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
