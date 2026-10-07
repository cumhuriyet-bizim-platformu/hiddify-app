import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/profile/data/core_options_builder.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/data/routing_list.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/notifier/warp_option/warp_option_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';

/// Derbent: the routing the core was last started with by the app: [mode] null means full VPN
/// without a list. Starts that bypass the app (Android boot, quick-settings tile) are not seen.
class AppliedRouting {
  const AppliedRouting(this.profileId, this.mode);
  final String profileId;
  final RoutingMode? mode;
}

final appliedRoutingProvider = StateProvider<AppliedRouting?>((ref) => null);

abstract interface class ConnectionRepository {
  SingboxConfigOption? get configOptionsSnapshot;

  TaskEither<ConnectionFailure, Unit> setup();
  Stream<ConnectionStatus> watchConnectionStatus();
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> disconnect();
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> refreshCoreOptions(ProfileEntity profile);
}

class ConnectionRepositoryImpl with ExceptionHandler, InfraLogger implements ConnectionRepository {
  ConnectionRepositoryImpl({
    required this.ref,
    required this.directories,
    required this.singbox,
    required this.configOptionRepository,
    required this.profilePathResolver,
    required this.optionsBuilder,
    required this.routingStore,
  });

  final Ref ref;

  final Directories directories;
  final HiddifyCoreService singbox;

  final ConfigOptionRepository configOptionRepository;
  final ProfilePathResolver profilePathResolver;
  final CoreOptionsBuilder optionsBuilder;
  final RoutingListStore routingStore;

  SingboxConfigOption? _configOptionsSnapshot;
  @override
  SingboxConfigOption? get configOptionsSnapshot => _configOptionsSnapshot;

  bool _initialized = false;

  @override
  TaskEither<ConnectionFailure, Unit> setup() {
    if (_initialized) return TaskEither.of(unit);
    return exceptionHandler(() {
      loggy.debug("setting up singbox");

      return singbox
          .setup()
          .map((r) {
            _initialized = true;
            return r;
          })
          .mapLeft(UnexpectedConnectionFailure.new)
          .run();
    }, UnexpectedConnectionFailure.new);
  }

  @override
  Stream<ConnectionStatus> watchConnectionStatus() {
    return singbox.watchStatus().map(
      (event) => switch (event) {
        CoreStopped() => Disconnected(event.getCoreAlert()),
        CoreStarting() => const Connecting(),
        CoreStarted() => const Connected(),
        CoreStopping() => const Disconnecting(),
      },
    );
  }

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) => setup().flatMap(
    (_) => applyConfigOption(activeProfile).flatMap(
      (_) => singbox
          .start(profilePathResolver.file(activeProfile.id).path, activeProfile.name, disableMemoryLimit)
          .flatMap((_) => _afterStart(activeProfile.id)),
      // .mapLeft(UnexpectedConnectionFailure.new),
    ),
  );

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() => singbox.stop().mapLeft(UnexpectedConnectionFailure.new);

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      applyConfigOption(activeProfile).flatMap(
        (_) => singbox
            .restart(profilePathResolver.file(activeProfile.id).path, activeProfile.name, disableMemoryLimit)
            .mapLeft<ConnectionFailure>(UnexpectedConnectionFailure.new)
            .flatMap((_) => _afterStart(activeProfile.id)),
      );

  /// Derbent: the active profile changed while disconnected. The core keeps the last options it was
  /// given for starts that bypass the app (Android boot, quick-settings tile), so hand it the new
  /// profile's options now. Nothing is started and no file is removed.
  @override
  TaskEither<ConnectionFailure, Unit> refreshCoreOptions(ProfileEntity profile) => optionsBuilder
      .build(profile.id, profile.profileOverride)
      .mapLeft((l) => ConnectionFailure.invalidConfigOption(null, l))
      .flatMap(
        (built) => TaskEither.tryCatch(() async {
          final res = await singbox.changeOptions(built.options).run();
          if (res case Left(:final value)) throw value;
          return unit;
        }, (err, st) => ConnectionFailure.unexpected(err, st)),
      );

  RoutingListState? _startingRouting;

  /// Derbent: after a successful start, record the routing the core now runs with (the status line
  /// compares it with the stored list) and remove this profile's rule-set files the new core does
  /// not use. Files are only removed here (never when a list is replaced or dropped), so a running
  /// core never loses the file it was started with; the stored list's file is always kept.
  TaskEither<ConnectionFailure, Unit> _afterStart(String profileId) => TaskEither(() async {
    try {
      ref.read(appliedRoutingProvider.notifier).state = AppliedRouting(profileId, _startingRouting?.mode);
      await routingStore.prune(profileId, keep: _startingRouting?.path);
    } catch (e, st) {
      loggy.warning("could not prune routing files", e, st);
    }
    return right(unit);
  });

  @visibleForTesting
  TaskEither<ConnectionFailure, Unit> applyConfigOption(ProfileEntity prof) => optionsBuilder
      .build(prof.id, prof.profileOverride)
      .mapLeft((l) => ConnectionFailure.invalidConfigOption(null, l))
      .flatMap(
        (built) => TaskEither.tryCatch(() async {
          final overridedOptions = built.options;
          final isWarpLicenseAgreed = ref.read(warpLicenseNotifierProvider);
          final isWarpEnabled = overridedOptions.warp.enable || overridedOptions.warp2.enable;
          if (!isWarpLicenseAgreed && isWarpEnabled) {
            final isAgreed = await ref.read(dialogNotifierProvider.notifier).showWarpLicense();
            if (isAgreed == true) {
              await ref.read(warpLicenseNotifierProvider.notifier).agree();
              // return (await applyConfigOption(prof).run()).match((l) => throw l, (_) => unit);
            } else {
              throw const MissingWarpLicense();
            }
          }
          _configOptionsSnapshot = overridedOptions;
          _startingRouting = built.routing;
          await singbox.changeOptions(overridedOptions).run();
          return unit;
        }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st)),
      );
}
