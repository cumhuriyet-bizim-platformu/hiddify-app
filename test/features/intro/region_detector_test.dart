import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/features/intro/widget/intro_page.dart';

void main() {
  group('RegionDetector.detectFrom (time zone + locale only)', () {
    test('Europe/Istanbul gives TR', () {
      expect(RegionDetector.detectFrom(offsetMinutes: 180, tzName: 'Europe/Istanbul', localeName: 'en_US'), 'TR');
    });

    test('a tr locale gives TR at +03', () {
      expect(RegionDetector.detectFrom(offsetMinutes: 180, tzName: '+03', localeName: 'tr_TR'), 'TR');
    });

    test('a tr locale gives TR even outside Turkey', () {
      expect(RegionDetector.detectFrom(offsetMinutes: -300, tzName: 'EST', localeName: 'tr'), 'TR');
    });

    test('a TR country with another language gives TR', () {
      expect(RegionDetector.detectFrom(offsetMinutes: 60, tzName: 'CET', localeName: 'en_TR'), 'TR');
    });

    test('unrecognized zone and locale give US', () {
      expect(RegionDetector.detectFrom(offsetMinutes: 60, tzName: 'CET', localeName: 'de_DE'), 'US');
      expect(RegionDetector.detectFrom(offsetMinutes: 0, tzName: 'GMT', localeName: 'en_GB'), 'US');
    });
  });

  group('IntroPage.regionLocaleFor', () {
    test('TR maps to Region.tr', () {
      expect(IntroPage.regionLocaleFor('TR').region, Region.tr);
    });

    test('unknown country maps to Region.other', () {
      expect(IntroPage.regionLocaleFor('US').region, Region.other);
      expect(IntroPage.regionLocaleFor('').region, Region.other);
    });
  });
}
