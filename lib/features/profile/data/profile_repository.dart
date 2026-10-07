import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';

import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/profile/data/core_options_builder.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/data/routing_list.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:uuid/uuid.dart';

abstract interface class ProfileRepository {
  TaskEither<ProfileFailure, Unit> init();
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id);
  TaskEither<ProfileFailure, Unit> setAsActive(String id);
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive);
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile();
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile();
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  });
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken});
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride});
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity nProfile, String nContent);
  TaskEither<ProfileFailure, Unit> validateConfig(
    String path,
    String tempPath,
    String? profileOverride,
    bool debug, {
    required String profileId,
  });
  TaskEither<ProfileFailure, String> generateConfig(String id);
  TaskEither<ProfileFailure, String> getRawConfig(String id);
}

class ProfileRepositoryImpl with ExceptionHandler, InfraLogger implements ProfileRepository {
  ProfileRepositoryImpl({
    required ProfileDataSource profileDataSource,
    required ProfilePathResolver profilePathResolver,
    required HiddifyCoreService singbox,
    required ProfileParser profileParser,
    required CoreOptionsBuilder optionsBuilder,
    RoutingListRefresher? routingRefresher,
  }) : _routingRefresher = routingRefresher,
       _optionsBuilder = optionsBuilder,
       _profileParser = profileParser,
       _singbox = singbox,
       _profilePathResolver = profilePathResolver,
       _profileDataSource = profileDataSource;

  final ProfileDataSource _profileDataSource;
  final ProfilePathResolver _profilePathResolver;
  final HiddifyCoreService _singbox;
  final ProfileParser _profileParser;
  final RoutingListRefresher? _routingRefresher;
  final CoreOptionsBuilder _optionsBuilder;

  @override
  TaskEither<ProfileFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await _profilePathResolver.directory.exists()) {
          await _profilePathResolver.directory.create(recursive: true);
        }
      }

      return right(unit);
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) {
    return TaskEither.tryCatch(
      () => _profileDataSource.getById(id).then((value) => value?.toEntity()),
      ProfileUnexpectedFailure.new,
    );
  }

  @override
  TaskEither<ProfileFailure, Unit> setAsActive(String id) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.edit(id, const ProfileEntriesCompanion(active: Value(true)));
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.deleteById(id, isActive);
      await _profilePathResolver.file(id).delete();
      await _routingRefresher?.store.remove(id);
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

  @override
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile() {
    return _profileDataSource.watchActiveProfile().map((event) => event?.toEntity()).handleExceptions((
      error,
      stackTrace,
    ) {
      loggy.error("error watching active profile", error, stackTrace);
      return ProfileUnexpectedFailure(error, stackTrace);
    });
  }

  @override
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile() {
    return _profileDataSource
        .watchProfilesCount()
        .map((event) => event != 0)
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) {
    return _profileDataSource
        .watchAll(sort: sort, sortMode: sortMode)
        .map((event) => event.map((e) => e.toEntity()).toList())
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken}) =>
      TaskEither.tryCatch(
        () async => await _profileDataSource.getByUrl(url).then((profEntry) => profEntry?.toEntity()),
        ProfileFailure.unexpected,
      ).flatMap((profEntity) {
        // if profile is null, generate id
        final id = profEntity?.id ?? const Uuid().v4();
        final file = _profilePathResolver.file(id);
        final tempFile = _profilePathResolver.tempFile(id);
        try {
          if (profEntity != null && profEntity is RemoteProfileEntity) {
            // Update
            if (userOverride != null) {
              profEntity = profEntity.copyWith(userOverride: userOverride);
            }
            return _profileParser
                .updateRemote(rp: profEntity, tempFilePath: tempFile.path, cancelToken: cancelToken)
                .flatMap(
                  (profEntity) =>
                      validateConfig(file.path, tempFile.path, profEntity.profileOverride.value, false, profileId: id)
                          .flatMap((_) => _refreshRoutingList(id, url, profEntity))
                          .flatMap(
                            (unit) => TaskEither.tryCatch(() async {
                              await _profileDataSource.edit(id, profEntity);
                              return unit;
                            }, ProfileFailure.unexpected),
                          )
                          .flatMap((_) => _restoreActiveCoreOptions()),
                );
          } else {
            // Add
            return _profileParser
                .addRemote(
                  id: id,
                  url: url,
                  tempFilePath: tempFile.path,
                  userOverride: userOverride,
                  cancelToken: cancelToken,
                )
                .flatMap(
                  (profEntity) =>
                      validateConfig(file.path, tempFile.path, profEntity.profileOverride.value, false, profileId: id)
                          .flatMap((_) => _refreshRoutingList(id, url, profEntity))
                          .flatMap(
                            (unit) => TaskEither.tryCatch(() async {
                              await _profileDataSource.insert(profEntity);
                              return unit;
                            }, ProfileFailure.unexpected),
                          )
                          .flatMap((_) => _restoreActiveCoreOptions()),
                );
          }
        } finally {
          if (tempFile.existsSync()) tempFile.deleteSync();
        }
      });

  /// Derbent: download, validate and store the panel's routing list after a successful subscription
  /// update, before the profile row is written (so the home status line re-reads the new list). Never
  /// fails the update: any problem leaves no list (full VPN) or the previous one if its hash matches.
  TaskEither<ProfileFailure, Unit> _refreshRoutingList(String id, String url, ProfileEntriesCompanion entry) =>
      TaskEither(() async {
        final refresher = _routingRefresher;
        if (refresher == null) return right(unit);
        try {
          String? raw;
          if (entry.populatedHeaders case Value(present: true, value: final String json)) {
            if (jsonDecode(json) case {'derbent-routing': final String v}) raw = v;
          }
          await refresher.refresh(profileId: id, subscriptionUrl: Uri.parse(url.trim()), rawHeader: raw);
        } catch (e, st) {
          loggy.warning("routing list refresh failed; full VPN", e, st);
        }
        return right(unit);
      });

  /// Derbent: validateConfig left the core holding the options of the profile it validated, built
  /// before its routing list was refreshed. Hand the core the active profile's options again, with
  /// the list now on disk, so a background start (Android boot, quick-settings tile) gets them.
  /// Never fails the update.
  TaskEither<ProfileFailure, Unit> _restoreActiveCoreOptions() => TaskEither(() async {
    try {
      final active = (await _profileDataSource.watchActiveProfile().first)?.toEntity();
      if (active != null) {
        final built = await _optionsBuilder.build(active.id, active.profileOverride).run();
        if (built case Right(value: (:final options, routing: _))) {
          await _singbox.changeOptions(options).run();
        }
      }
    } catch (e, st) {
      loggy.warning("could not refresh the core options for the active profile", e, st);
    }
    return right(unit);
  });

  @override
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride}) =>
      TaskEither.tryCatch(() async {
        final id = const Uuid().v4();
        final file = _profilePathResolver.file(id);
        final tempFile = _profilePathResolver.tempFile(id);
        try {
          await tempFile.writeAsString(content);
          final task = _profileParser
              .addLocal(id: id, content: content, tempFilePath: tempFile.path, userOverride: userOverride)
              .flatMap(
                (profEntity) =>
                    validateConfig(
                      file.path,
                      tempFile.path,
                      profEntity.profileOverride.value,
                      false,
                      profileId: id,
                    ).flatMap(
                      (unit) => TaskEither.tryCatch(() async {
                        await _profileDataSource.insert(profEntity);
                        return unit;
                      }, ProfileFailure.unexpected),
                    ),
              );
          return (await task.run()).getOrElse((l) => throw l);
        } finally {
          if (tempFile.existsSync()) tempFile.deleteSync();
        }
      }, ProfileFailure.unexpected);

  @override
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity profile, String nContent) =>
      TaskEither.tryCatch(
        () async => await _profileDataSource.getById(profile.id).then((profEntry) => profEntry?.toEntity()),
        ProfileFailure.unexpected,
      ).flatMap((oProfile) {
        if (oProfile == null || oProfile.runtimeType != profile.runtimeType) throw const ProfileFailure.notFound();
        if (profile.userOverride == null) loggy.warning('Updaing profile content with "userOverride" == null');
        final id = oProfile.id;
        final file = _profilePathResolver.file(id);
        final tempFile = _profilePathResolver.tempFile(id);
        try {
          return TaskEither.tryCatch(
            () async => await tempFile.writeAsString(nContent),
            ProfileFailure.unexpected,
          ).flatMap(
            (_) =>
                TaskEither.fromEither(
                  _profileParser.offlineUpdate(
                    profile: oProfile.copyWith(userOverride: profile.userOverride),
                    tempFilePath: tempFile.path,
                  ),
                ).flatMap(
                  (profEntity) =>
                      validateConfig(
                        file.path,
                        tempFile.path,
                        profEntity.profileOverride.value,
                        false,
                        profileId: id,
                      ).flatMap(
                        (unit) => TaskEither.tryCatch(() async {
                          await _profileDataSource.edit(id, profEntity);
                          return unit;
                        }, ProfileFailure.unexpected),
                      ),
                ),
          );
        } finally {
          if (tempFile.existsSync()) tempFile.deleteSync();
        }
      });

  /// The core persists the options sent here and reuses them for background starts, so they are
  /// built like a connect's (the shared [CoreOptionsBuilder], routing fields included).
  @override
  TaskEither<ProfileFailure, Unit> validateConfig(
    String path,
    String tempPath,
    String? profileOverride,
    bool debug, {
    required String profileId,
  }) => _optionsBuilder
      .build(profileId, profileOverride)
      .mapLeft((configOptionFailure) => ProfileFailure.invalidConfig(null, configOptionFailure))
      .flatMap(
        (built) => _singbox
            .changeOptions(built.options)
            .mapLeft(ProfileFailure.invalidConfig)
            .flatMap((_) => _singbox.validateConfigByPath(path, tempPath, debug).mapLeft(ProfileFailure.invalidConfig)),
      );

  @override
  TaskEither<ProfileFailure, String> generateConfig(String id) => TaskEither.fromEither(
    Either.tryCatch(() => _profilePathResolver.file(id), ProfileFailure.unexpected),
  ).flatMap((configFile) => _singbox.generateFullConfigByPath(configFile.path).mapLeft(ProfileFailure.unexpected));

  @override
  TaskEither<ProfileFailure, String> getRawConfig(String id) {
    return TaskEither.fromEither(
      Either.tryCatch(() => _profilePathResolver.file(id), ProfileFailure.unexpected),
    ).flatMap((configFile) => TaskEither.tryCatch(() => configFile.readAsString(), ProfileFailure.unexpected));
  }
}
