import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';

abstract class GithubReleaseParser {
  // Derbent: app release tags are v<upstream x.y.z>-derbent.<N>, with a trailing .dev for pre-releases.
  static final _appTag = RegExp(r'^v(\d+\.\d+\.\d+)-derbent\.(\d+)(\.dev)?$');

  /// derbent-releases also holds core-v… and server-v… releases; only `v<x.y.z>-derbent.<N>[.dev]` tags are app releases.
  static bool isAppRelease(Map<String, dynamic> json) => _appTag.hasMatch(json['tag_name'] as String? ?? '');

  /// Only call for tags accepted by [isAppRelease]; anything else throws [FormatException].
  static RemoteVersionEntity parse(Map<String, dynamic> json) {
    final fullTag = json['tag_name'] as String;
    final match = _appTag.firstMatch(fullTag);
    if (match == null) throw FormatException("not a Derbent app release tag", fullTag);
    final preRelease = json["prerelease"] as bool;
    final publishedAt = DateTime.parse(json["published_at"] as String);
    return RemoteVersionEntity(
      version: match.group(1)!,
      buildNumber: "",
      derbentRelease: int.parse(match.group(2)!),
      releaseTag: fullTag,
      preRelease: preRelease,
      url: json["html_url"] as String,
      publishedAt: publishedAt,
      flavor: match.group(3) != null ? Environment.dev : Environment.prod,
    );
  }
}
