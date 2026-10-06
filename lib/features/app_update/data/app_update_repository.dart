import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/utils/utils.dart';

abstract interface class AppUpdateRepository {
  /// Right(null) means no matching app release exists (treated as "no update").
  TaskEither<AppUpdateFailure, RemoteVersionEntity?> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  });
}

class AppUpdateRepositoryImpl with ExceptionHandler, InfraLogger implements AppUpdateRepository {
  AppUpdateRepositoryImpl({required this.httpClient, required this.proxyOnly});

  final DioHttpClient httpClient;

  /// Evaluated per request. True means the GitHub call must go through the local proxy only.
  final bool Function() proxyOnly;

  static const _perPage = 100;
  static const _maxPages = 5;

  @override
  TaskEither<AppUpdateFailure, RemoteVersionEntity?> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  }) {
    return exceptionHandler(() async {
      if (!release.allowCustomUpdateChecker) {
        throw Exception("custom update checkers are not supported");
      }
      RemoteVersionEntity? latest;
      for (var page = 1; page <= _maxPages && latest == null; page++) {
        // Derbent: while the VPN is up (or switching) this check is proxy-only. The default client
        // would fall back to a direct connection if the proxy port looks closed, leaking a GitHub
        // contact outside the tunnel. A proxy failure surfaces as AppUpdateFailure, never as DIRECT.
        final response = await httpClient.get<List>(
          '${Constants.githubReleasesApiUrl}?per_page=$_perPage&page=$page',
          proxyOnly: proxyOnly(),
        );
        if (response.statusCode != 200 || response.data == null) {
          loggy.warning("failed to fetch latest version info (page $page)");
          return left(const AppUpdateFailure.unexpected());
        }
        final raw = response.data!;
        if (raw.isEmpty) break;
        final lastPage = raw.length < _perPage;

        final releases = raw
            .cast<Map<String, dynamic>>()
            .where(GithubReleaseParser.isAppRelease)
            .map(GithubReleaseParser.parse);
        latest = includePreReleases ? releases.firstOrNull : releases.where((e) => e.preRelease == false).firstOrNull;
        if (lastPage) break;
      }
      if (latest == null) loggy.info("no app release found in the fetched releases");
      return right(latest);
    }, AppUpdateFailure.unexpected);
  }
}
