import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/home/widget/routing_status_line.dart';
import 'package:hiddify/features/profile/data/routing_list.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

Future<void> pumpLine(WidgetTester tester, RoutingListState? state) async {
  final container = ProviderContainer(
    overrides: [
      translationsProvider.overrideWith((ref) => AppLocale.en.buildSync()),
      routingStatusProvider.overrideWith((ref) => state),
    ],
  );
  addTearDown(container.dispose);
  await container.read(translationsProvider.future);
  await container.read(routingStatusProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: RoutingStatusLine())),
    ),
  );
  await tester.pumpAndSettle();
}

RoutingListState state(RoutingMode mode, int count) =>
    RoutingListState(mode: mode, count: count, sha256: 'a' * 64, path: '/data/configs/p1.routing-${mode.name}.json');

void main() {
  testWidgets('whitelist list → "Whitelist: N sites via VPN, the rest direct"', (tester) async {
    await pumpLine(tester, state(RoutingMode.whitelist, 42));
    expect(find.text('Whitelist: 42 sites via VPN, the rest direct'), findsOneWidget);
  });

  testWidgets('full list → "Full VPN: N services direct"', (tester) async {
    await pumpLine(tester, state(RoutingMode.full, 7));
    expect(find.text('Full VPN: 7 services direct'), findsOneWidget);
  });

  testWidgets('no valid list → nothing, never "whitelist active"', (tester) async {
    await pumpLine(tester, null);
    expect(find.byType(Text), findsNothing);
    expect(find.textContaining('Whitelist'), findsNothing);
  });
}
