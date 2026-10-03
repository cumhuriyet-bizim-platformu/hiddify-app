import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('exit-IP auto check defaults to off', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);

    expect(container.read(Preferences.autoCheckIp), isFalse);
  });

  test('an explicit user choice is kept', () async {
    SharedPreferences.setMockInitialValues({'auto_check_ip': true});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);

    expect(container.read(Preferences.autoCheckIp), isTrue);
  });
}
