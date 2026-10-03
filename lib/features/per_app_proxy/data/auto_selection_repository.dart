import 'package:flutter/services.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum AutoSelectionResult {
  success,
  failure,
  notFound;

  bool isSuccess() => this == success;
  bool isFailure() => this == failure;
  bool isNotFound() => this == notFound;
}

abstract interface class AutoSelectionRepository {
  Future<(Set<String>?, AutoSelectionResult)> getByAppProxyMode({AppProxyMode? mode, Region? region});
  Future<(Set<String>?, AutoSelectionResult)> getInclude({Region? region});
  Future<(Set<String>?, AutoSelectionResult)> getExclude({Region? region});
}

class AutoSelectionRepositoryImpl with AppLogger implements AutoSelectionRepository {
  AutoSelectionRepositoryImpl({required Ref ref, AssetBundle? bundle}) : _ref = ref, _bundle = bundle ?? rootBundle;
  final Ref _ref;
  final AssetBundle _bundle;

  /// Bundled snapshot of hiddify/Android-GFW-Apps @ 8b4150811d46cee3dde5ddb762d1d181478b5b30 (GPL-3.0).
  static const assetDir = 'assets/per_app/android_gfw_apps';

  @override
  Future<(Set<String>?, AutoSelectionResult)> getByAppProxyMode({AppProxyMode? mode, Region? region}) async =>
      await _makeRequest(mode: mode ?? _getMode(), region: region ?? _getRegion());

  @override
  Future<(Set<String>?, AutoSelectionResult)> getExclude({Region? region}) async =>
      await _makeRequest(mode: AppProxyMode.exclude, region: region ?? _getRegion());

  @override
  Future<(Set<String>?, AutoSelectionResult)> getInclude({Region? region}) async =>
      await _makeRequest(mode: AppProxyMode.include, region: region ?? _getRegion());

  Future<(Set<String>?, AutoSelectionResult)> _makeRequest({required AppProxyMode mode, Region? region}) async {
    final r = region ?? _getRegion();
    final String content;
    try {
      content = await _bundle.loadString(assetPath(mode, r), cache: false);
    } catch (e) {
      loggy.warning("no bundled auto selection list for region [${r.name}]");
      return (null, AutoSelectionResult.notFound);
    }
    try {
      return (_parseToListOfString(content), AutoSelectionResult.success);
    } catch (e, st) {
      loggy.error("Failed to parse bundled auto selection list", e, st);
      return (null, AutoSelectionResult.failure);
    }
  }

  static String assetPath(AppProxyMode mode, Region region) => switch (mode) {
    AppProxyMode.include => '$assetDir/proxy_${region.name}',
    AppProxyMode.exclude => '$assetDir/direct_${region.name}',
  };

  Set<String> _parseToListOfString(dynamic data) =>
      data.toString().split('\n').map((e) => e.trim()).where((element) => element.isNotEmpty).toSet();

  AppProxyMode _getMode() => _ref.read(Preferences.perAppProxyMode).toAppProxy()!;

  Region _getRegion() => _ref.read(ConfigOptions.region);
}
