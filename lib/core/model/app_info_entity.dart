import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';

part 'app_info_entity.freezed.dart';

@freezed
class AppInfoEntity with _$AppInfoEntity {
  const AppInfoEntity._();

  const factory AppInfoEntity({
    required String name,
    required String version,
    required String buildNumber,
    required Release release,
    required String operatingSystem,
    required String operatingSystemVersion,
    required Environment environment,
  }) = _AppInfoEntity;

  String get userAgent => "HiddifyNext/$version ($operatingSystem) like ClashMeta v2ray sing-box";

  // Derbent: show the release number too; 4.1.2-derbent.2 and 4.1.2-derbent.3 share an upstream version.
  String get presentVersion {
    const full = "-derbent.${Constants.derbentRelease}";
    return environment == Environment.prod ? "$version$full" : "$version$full ${environment.name}";
  }

  /// formats app info for sharing
  String format() =>
      '''
$name v$version ($buildNumber) [${environment.name}]
${release.name} release
$operatingSystem [$operatingSystemVersion]''';
}
