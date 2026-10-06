import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';

Map<String, dynamic> _release(String tag, {bool pre = false}) => {
  'tag_name': tag,
  'prerelease': pre,
  'published_at': '2026-10-01T00:00:00Z',
  'html_url': 'https://github.com/cumhuriyet-bizim-platformu/derbent-releases/releases/tag/$tag',
};

void main() {
  test('manual check uses derbent-releases', () {
    expect(
      Constants.githubReleasesApiUrl,
      'https://api.github.com/repos/cumhuriyet-bizim-platformu/derbent-releases/releases',
    );
  });

  group('Release.customUpdateCheckerAllowed (APK and desktop only)', () {
    test('general APK build on Android', () {
      expect(Release.customUpdateCheckerAllowed(Release.general, isAndroid: true, isDesktop: false), isTrue);
    });
    test('desktop build', () {
      expect(Release.customUpdateCheckerAllowed(Release.general, isAndroid: false, isDesktop: true), isTrue);
    });
    test('iOS build', () {
      expect(Release.customUpdateCheckerAllowed(Release.general, isAndroid: false, isDesktop: false), isFalse);
    });
    test('Google Play (AAB) build', () {
      expect(Release.customUpdateCheckerAllowed(Release.googlePlay, isAndroid: true, isDesktop: false), isFalse);
    });
  });

  group('GithubReleaseParser.isAppRelease', () {
    test('app tags are kept', () {
      expect(GithubReleaseParser.isAppRelease(_release('v4.1.2-derbent.1')), isTrue);
      expect(GithubReleaseParser.isAppRelease(_release('v4.1.3-derbent.1.dev', pre: true)), isTrue);
    });
    test('core and server tags in derbent-releases are ignored', () {
      expect(GithubReleaseParser.isAppRelease(_release('core-v4.1.0-derbent.1')), isFalse);
      expect(GithubReleaseParser.isAppRelease(_release('server-v11.0.0')), isFalse);
      expect(GithubReleaseParser.isAppRelease({'prerelease': false}), isFalse);
    });
    test('an app tag still parses', () {
      expect(GithubReleaseParser.parse(_release('v4.1.2-derbent.1')).version, '4.1.2');
    });
  });
}
