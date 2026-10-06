import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/core/model/environment.dart';

part 'remote_version_entity.freezed.dart';

@Freezed()
class RemoteVersionEntity with _$RemoteVersionEntity {
  const RemoteVersionEntity._();

  const factory RemoteVersionEntity({
    required String version,
    required String buildNumber,
    // Derbent: the <N> of the release tag v<x.y.z>-derbent.<N>.
    required int derbentRelease,
    required String releaseTag,
    required bool preRelease,
    required String url,
    required DateTime publishedAt,
    required Environment flavor,
  }) = _RemoteVersionEntity;

  // Derbent: include the release number, since several releases share one upstream version.
  String get presentVersion =>
      flavor == Environment.prod ? "$version-derbent.$derbentRelease" : "$version-derbent.$derbentRelease ${flavor.name}";
}
