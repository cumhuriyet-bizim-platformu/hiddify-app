import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/features/per_app_proxy/data/auto_selection_repository.dart';
import 'package:hiddify/features/per_app_proxy/data/auto_selection_repository_provider.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late AutoSelectionRepository repo;

  setUp(() {
    container = ProviderContainer();
    repo = container.read(autoSelectionRepoProvider);
  });
  tearDown(() => container.dispose());

  test('asset paths', () {
    expect(
      AutoSelectionRepositoryImpl.assetPath(AppProxyMode.include, Region.ir),
      'assets/per_app/android_gfw_apps/proxy_ir',
    );
    expect(
      AutoSelectionRepositoryImpl.assetPath(AppProxyMode.exclude, Region.cn),
      'assets/per_app/android_gfw_apps/direct_cn',
    );
  });

  test('include list comes from the bundled snapshot', () async {
    final (pkgs, result) = await repo.getByAppProxyMode(mode: AppProxyMode.include, region: Region.cn);
    expect(result, AutoSelectionResult.success);
    expect(pkgs, contains('air.com.rosettastone.mobile.CoursePlayer'));
  });

  test('exclude list comes from the bundled snapshot', () async {
    final (pkgs, result) = await repo.getByAppProxyMode(mode: AppProxyMode.exclude, region: Region.ir);
    expect(result, AutoSelectionResult.success);
    expect(pkgs, contains('air.com.viraparsian.mishakoosha'));
  });

  test('a region without a list is notFound (no network fallback)', () async {
    final (pkgs, result) = await repo.getByAppProxyMode(mode: AppProxyMode.include, region: Region.tr);
    expect(result, AutoSelectionResult.notFound);
    expect(pkgs, isNull);
  });
}
