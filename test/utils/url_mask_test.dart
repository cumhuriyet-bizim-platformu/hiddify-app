import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/utils/url_mask.dart';

void main() {
  group('maskUrl', () {
    test('keeps scheme and host, hides path and query', () {
      expect(maskUrl('https://sub.example.com/api/v1/abcdef?token=secret#x'), 'https://sub.example.com/…');
    });

    test('drops user info but keeps an explicit port', () {
      expect(maskUrl('https://user:pass@example.com:8443/sub'), 'https://example.com:8443/…');
    });

    test('bare host still gets the ellipsis', () {
      expect(maskUrl('https://example.com'), 'https://example.com/…');
    });

    test('custom schemes keep only their host part', () {
      expect(maskUrl('hiddify://import/https://example.com/sub?x=1'), 'hiddify://import/…');
    });

    test('host-less URIs keep only the scheme', () {
      expect(maskUrl('file:///Users/me/secret.json'), 'file:…');
      expect(maskUrl('mailto:someone@example.com'), 'mailto:…');
    });

    test('things that are not URLs are fully hidden', () {
      expect(maskUrl('example.com/path?q=1'), '…');
      expect(maskUrl(''), '…');
    });
  });

  test('maskUri matches maskUrl', () {
    expect(maskUri(Uri.parse('https://example.com/a/b?c=d')), 'https://example.com/…');
  });
}
