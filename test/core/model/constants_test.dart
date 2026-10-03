import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/constants.dart';

void main() {
  test('terms and privacy links default to empty, so they are hidden', () {
    expect(Constants.termsAndConditionsUrl, isEmpty);
    expect(Constants.privacyPolicyUrl, isEmpty);
  });

  test('credits stay: source code and license links are unchanged', () {
    expect(Constants.githubUrl, 'https://github.com/hiddify/hiddify-next');
    expect(Constants.licenseUrl, 'https://github.com/hiddify/hiddify-next?tab=License-1-ov-file#readme');
  });
}
