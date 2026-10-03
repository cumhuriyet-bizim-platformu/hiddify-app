import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/widget/profile_tile_main.dart';

void main() {
  test('the verified-link list is empty', () {
    expect(ProfileTileMain.verifiedDomains, isEmpty);
    expect(ProfileTileMain.verifiedLinks, isEmpty);
  });

  test('former Hiddify links are no longer opened without a warning', () {
    for (final url in [
      'https://t.me/hiddify',
      'https://t.me/hiddify_board',
      'https://hiddify.com/',
      'https://docs.hiddify.com/x',
      'https://instagram.com/hiddify_com',
    ]) {
      expect(ProfileTileMain.isVerifiedLink(url), isFalse, reason: url);
    }
  });
}
