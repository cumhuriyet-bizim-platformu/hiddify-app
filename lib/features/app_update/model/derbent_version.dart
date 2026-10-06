import 'package:version/version.dart';

/// Derbent: releases are tagged `v<upstream x.y.z>-derbent.<N>`, so the same upstream version ships
/// several times (security fixes). A remote release is newer when (upstream semver, N) is greater
/// in lexicographic order: upstream first, then N.
bool isNewerDerbentRelease({
  required String remoteVersion,
  required int remoteRelease,
  required String localVersion,
  required int localRelease,
}) {
  final remote = Version.parse(remoteVersion);
  final local = Version.parse(localVersion);
  if (remote != local) return remote > local;
  return remoteRelease > localRelease;
}

/// Derbent: the ignore preference stores the full release tag (v4.1.2-derbent.2), so ignoring one
/// release never hides a later one of the same upstream version.
bool isIgnoredRelease(String releaseTag, String? ignoredTag) => ignoredTag != null && releaseTag == ignoredTag;
