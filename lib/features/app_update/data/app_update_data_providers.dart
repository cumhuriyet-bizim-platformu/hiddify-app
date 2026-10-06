import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/features/app_update/data/app_update_repository.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_update_data_providers.g.dart';

@Riverpod(keepAlive: true)
AppUpdateRepository appUpdateRepository(AppUpdateRepositoryRef ref) {
  return AppUpdateRepositoryImpl(
    httpClient: ref.watch(httpClientProvider),
    // Derbent: read at request time (no rebuild). Only a fully disconnected VPN may go direct;
    // connected, connecting and disconnecting are all proxy-only (the proxy port may be up, and if it
    // is not, the check fails cleanly instead of leaking a direct GitHub contact).
    proxyOnly: () => !(ref.read(connectionNotifierProvider).valueOrNull ?? const Disconnected()).isDisconnected,
  );
}
