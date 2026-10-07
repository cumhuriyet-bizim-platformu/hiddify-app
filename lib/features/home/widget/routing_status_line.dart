import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/routing_list.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Derbent: the routing list stored for the active profile, or null (full VPN). Re-read whenever the
/// active profile row changes; the list is refreshed before a subscription update is written to the
/// database, so the new row already sees the new list.
final routingStatusProvider = FutureProvider<RoutingListState?>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return null;
  return ref.watch(routingListStoreProvider).current(profile.id);
});

/// Null when there is no valid list: nothing is shown, never "whitelist active".
String? routingStatusText(Translations t, RoutingListState? state) => switch (state) {
  null => null,
  RoutingListState(mode: RoutingMode.whitelist, :final count) => t.pages.home.routing.whitelist(n: count),
  RoutingListState(mode: RoutingMode.full, :final count) => t.pages.home.routing.full(n: count),
};

/// Derbent: read-only status of the panel's routing mode. The mode is set per user on the panel and
/// cannot be changed in the app.
class RoutingStatusLine extends HookConsumerWidget {
  const RoutingStatusLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final text = routingStatusText(t, ref.watch(routingStatusProvider).valueOrNull);
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
