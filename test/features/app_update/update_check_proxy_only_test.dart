import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/app_update/data/update_check_proxy_only.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';

void main() {
  group('updateCheckProxyOnly', () {
    test('known Disconnected is the only status that may go direct', () {
      expect(updateCheckProxyOnly(const AsyncData<ConnectionStatus>(Disconnected())), isFalse);
    });
    for (final s in <ConnectionStatus>[const Connected(), const Connecting(), const Disconnecting()]) {
      test('${s.runtimeType} is proxy-only', () {
        expect(updateCheckProxyOnly(AsyncData<ConnectionStatus>(s)), isTrue);
      });
    }
    test('loading (unknown) is proxy-only', () {
      expect(updateCheckProxyOnly(const AsyncLoading<ConnectionStatus>()), isTrue);
    });
    test('error (unknown) is proxy-only', () {
      expect(updateCheckProxyOnly(AsyncError<ConnectionStatus>('x', StackTrace.empty)), isTrue);
    });
  });
}
