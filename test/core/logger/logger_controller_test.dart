import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/logger/logger_controller.dart';
import 'package:loggy/loggy.dart';

void main() {
  test('default app log level is warning', () {
    expect(LoggerController.defaultLogLevel, LogLevel.warning);
  });
}
