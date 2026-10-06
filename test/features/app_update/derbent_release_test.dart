import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';
import 'package:hiddify/features/app_update/model/derbent_version.dart';

Map<String, dynamic> _release(String tag, {bool pre = false}) => {
  'tag_name': tag,
  'prerelease': pre,
  'published_at': '2026-10-01T00:00:00Z',
  'html_url': 'https://github.com/cumhuriyet-bizim-platformu/derbent-releases/releases/tag/$tag',
};

void main() {
  test('a build without --dart-define=DERBENT_RELEASE is Derbent release 0', () {
    expect(Constants.derbentRelease, 0);
  });

  group('GithubReleaseParser.parse (Derbent tags)', () {
    test('v4.1.2-derbent.1', () {
      final r = GithubReleaseParser.parse(_release('v4.1.2-derbent.1'));
      expect(r.version, '4.1.2');
      expect(r.derbentRelease, 1);
      expect(r.flavor, Environment.prod);
      expect(r.releaseTag, 'v4.1.2-derbent.1');
    });
    test('v4.1.2-derbent.12 (two digits)', () {
      final r = GithubReleaseParser.parse(_release('v4.1.2-derbent.12'));
      expect(r.version, '4.1.2');
      expect(r.derbentRelease, 12);
      expect(r.flavor, Environment.prod);
    });
    test('v4.1.2-derbent.3.dev is flavor dev, N=3', () {
      final r = GithubReleaseParser.parse(_release('v4.1.2-derbent.3.dev', pre: true));
      expect(r.version, '4.1.2');
      expect(r.derbentRelease, 3);
      expect(r.flavor, Environment.dev);
      expect(r.releaseTag, 'v4.1.2-derbent.3.dev');
    });
  });

  group('GithubReleaseParser.isAppRelease (strict Derbent app tags)', () {
    for (final tag in ['v4.1.2-derbent.1', 'v4.1.2-derbent.12', 'v4.1.2-derbent.3.dev', 'v10.20.30-derbent.0']) {
      test('accepts $tag', () => expect(GithubReleaseParser.isAppRelease(_release(tag)), isTrue));
    }
    for (final tag in [
      'core-v4.1.0-derbent.1',
      'server-v14.0.0b5',
      'v4.1.2',
      'v4.1.2.dev',
      'v4.1.2-derbent',
      'v4.1.2-derbent.1.beta',
      'v4.1.2-derbent.1-extra',
      'v4.1.2-derbent.x',
    ]) {
      test('rejects $tag', () => expect(GithubReleaseParser.isAppRelease(_release(tag)), isFalse));
    }
  });

  group('isNewerDerbentRelease compares (upstream semver, N)', () {
    bool newer(String rv, int rn, String lv, int ln) =>
        isNewerDerbentRelease(remoteVersion: rv, remoteRelease: rn, localVersion: lv, localRelease: ln);

    test('same upstream, higher N is newer', () => expect(newer('4.1.2', 2, '4.1.2', 1), isTrue));
    test('higher upstream beats higher local N', () => expect(newer('4.1.3', 1, '4.1.2', 5), isTrue));
    test('the same pair is not newer', () => expect(newer('4.1.2', 1, '4.1.2', 1), isFalse));
    test('lower N is not newer', () => expect(newer('4.1.2', 1, '4.1.2', 2), isFalse));
    test('lower upstream is not newer even with higher N', () => expect(newer('4.1.1', 9, '4.1.2', 1), isFalse));
    test(
      'a dev build (N=0) is offered derbent.1 of the same upstream',
      () => expect(newer('4.1.2', 1, '4.1.2', 0), isTrue),
    );
    test('N compares numerically, not as text', () => expect(newer('4.1.2', 10, '4.1.2', 9), isTrue));
  });

  group('ignore preference holds the full release tag', () {
    test('ignoring derbent.2 does not hide derbent.3', () {
      expect(isIgnoredRelease('v4.1.2-derbent.3', 'v4.1.2-derbent.2'), isFalse);
    });
    test('the ignored tag itself stays hidden', () {
      expect(isIgnoredRelease('v4.1.2-derbent.2', 'v4.1.2-derbent.2'), isTrue);
    });
    test('a legacy bare-version value hides nothing', () {
      expect(isIgnoredRelease('v4.1.2-derbent.2', '4.1.2'), isFalse);
    });
    test('nothing ignored', () => expect(isIgnoredRelease('v4.1.2-derbent.2', null), isFalse));
  });

  test('presentVersion shows the Derbent release number', () {
    expect(GithubReleaseParser.parse(_release('v4.1.2-derbent.3')).presentVersion, '4.1.2-derbent.3');
    expect(GithubReleaseParser.parse(_release('v4.1.2-derbent.3.dev')).presentVersion, '4.1.2-derbent.3 dev');
  });
}
