import 'package:dartx/dartx.dart';
import 'package:hiddify/utils/platform_utils.dart';

enum Environment {
  prod,
  dev;

  // This environment variable is set in the 'windows-release-zip' command
  static const isPortable = bool.fromEnvironment("portable");
}

enum Release {
  general("general"),
  // This environment variable is set in the 'android-release-aab' command
  googlePlay("google-play");

  const Release(this.key);

  final String key;

  /// "Check for updates" exists only in APK (non-Play) and desktop builds.
  bool get allowCustomUpdateChecker =>
      customUpdateCheckerAllowed(this, isAndroid: PlatformUtils.isAndroid, isDesktop: PlatformUtils.isDesktop);

  static bool customUpdateCheckerAllowed(Release release, {required bool isAndroid, required bool isDesktop}) =>
      release == general && (isAndroid || isDesktop);

  static Release read() =>
      Release.values.firstOrNullWhere((e) => e.key == const String.fromEnvironment("release")) ?? Release.general;
}
