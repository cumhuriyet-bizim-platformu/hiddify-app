import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/profile/data/routing_list.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/model/config_option_failure.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';

typedef CoreOptions = ({SingboxConfigOption options, RoutingListState? routing});

/// Derbent: the one place that builds the options handed to the core, for every path that sends
/// them (connect, reconnect, config validation, the active-profile switch while disconnected).
///
/// The core persists the last options it was given and reuses them for starts that never pass
/// through the app (Android boot, quick-settings tile), so a path that sent options without the
/// routing fields would start the next background session without whitelist mode.
///
/// Order matters: the user settings, then the profile override, then the routing fields from the
/// validated list on disk for that profile, so no override can set or keep them. No list → both
/// fields null → omitted from the JSON → full VPN.
class CoreOptionsBuilder {
  const CoreOptionsBuilder({required this.configOptionRepository, required this.store});

  final ConfigOptionRepository configOptionRepository;
  final RoutingListStore store;

  TaskEither<ConfigOptionFailure, CoreOptions> build(String profileId, String? profileOverride) =>
      TaskEither.fromEither(configOptionRepository.fullOptionsOverrided(profileOverride)).flatMap(
        (overridden) => TaskEither.tryCatch(() async {
          final routing = await store.current(profileId);
          return (options: applyRoutingOptions(overridden, routing), routing: routing);
        }, ConfigOptionFailure.unexpected),
      );
}
