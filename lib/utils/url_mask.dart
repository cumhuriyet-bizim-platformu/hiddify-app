/// Masks a URL for logging: only scheme, host and explicit port are kept.
/// `https://host/path?query` is logged as `https://host/…`. User info, path,
/// query and fragment are never logged.
String maskUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return '…';
  return maskUri(uri);
}

String maskUri(Uri uri) {
  if (!uri.hasScheme) return '…';
  if (uri.host.isEmpty) return '${uri.scheme}:…';
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port/…';
}
