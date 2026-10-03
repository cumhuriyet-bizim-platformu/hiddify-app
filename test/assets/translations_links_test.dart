import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the no-profile help button carries no Hiddify link in any locale', () {
    final files = Directory('assets/translations')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.i18n.json'))
        .toList();
    expect(files, hasLength(11));
    for (final f in files) {
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final dialogs = json['dialogs'] as Map<String, dynamic>;
      final noActiveProfile = dialogs['noActiveProfile'] as Map<String, dynamic>;
      final helpBtn = noActiveProfile['helpBtn'] as Map<String, dynamic>;
      expect(helpBtn['url'], isEmpty, reason: f.path);
    }
  });

  test('no translation contains a hiddify.com link', () {
    for (final f in Directory('assets/translations').listSync().whereType<File>()) {
      expect(f.readAsStringSync().contains('hiddify.com'), isFalse, reason: f.path);
    }
  });
}
