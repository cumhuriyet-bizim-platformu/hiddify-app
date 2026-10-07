import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/singbox/model/core_status.dart';

void main() {
  group('notification permission alert', () {
    test('is not a connection failure', () {
      const status = CoreStatus.stopped(alert: CoreAlert.requestNotificationPermission);
      expect(status.getCoreAlert(), isNull);
    });

    test('is parsed from the Android event and stays informational', () {
      final status = CoreStatus.fromEvent({'status': 'Stopped', 'alert': 'RequestNotificationPermission'});
      expect(status, isA<CoreStopped>());
      expect((status as CoreStopped).alert, CoreAlert.requestNotificationPermission);
      expect(status.isInformationalAlert, isTrue);
      expect(status.getCoreAlert(), isNull);
    });

    test('real failures still map to a failure', () {
      const status = CoreStatus.stopped(alert: CoreAlert.startService, message: 'x');
      expect(status.getCoreAlert(), isNotNull);
      expect(status.isInformationalAlert, isFalse);
    });
  });
}
