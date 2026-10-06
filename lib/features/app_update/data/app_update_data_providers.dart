import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/features/app_update/data/app_update_repository.dart';
import 'package:hiddify/features/app_update/data/update_check_proxy_only.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_update_data_providers.g.dart';

@Riverpod(keepAlive: true)
AppUpdateRepository appUpdateRepository(AppUpdateRepositoryRef ref) {
  return AppUpdateRepositoryImpl(
    httpClient: ref.watch(httpClientProvider),
    // Derbent: read at request time (no rebuild). Only a known Disconnected status may go direct; an
    // unknown status (loading or error) means proxy-only, like connected, connecting and disconnecting.
    proxyOnly: () => updateCheckProxyOnly(ref.read(connectionNotifierProvider)),
  );
}
