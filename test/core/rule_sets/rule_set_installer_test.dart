import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/rule_sets/rule_set_installer.dart';
import 'package:path/path.dart' as p;

class _MapAssetBundle extends CachingAssetBundle {
  _MapAssetBundle(this.assets);

  final Map<String, List<int>> assets;
  final loaded = <String>[];

  @override
  Future<ByteData> load(String key) async {
    loaded.add(key);
    final bytes = assets[key];
    if (bytes == null) throw FlutterError('missing asset $key');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

_MapAssetBundle _bundle(String manifest, Map<String, String> files) => _MapAssetBundle({
  '${RuleSetInstaller.assetDir}/${RuleSetInstaller.manifestName}': utf8.encode(manifest),
  for (final entry in files.entries) '${RuleSetInstaller.assetDir}/${entry.key}': utf8.encode(entry.value),
});

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rule_set_installer_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('copies every file listed in the manifest', () async {
    const manifest = 'aaa  block/geoip-malware.srs\nbbb  country/geoip-tr.srs\n';
    final bundle = _bundle(manifest, {'block/geoip-malware.srs': 'M', 'country/geoip-tr.srs': 'T'});
    final target = RuleSetInstaller.dirFor(tmp);

    final wrote = await RuleSetInstaller(bundle: bundle, targetDir: target).install();

    expect(wrote, isTrue);
    expect(File(p.join(target.path, 'block', 'geoip-malware.srs')).readAsStringSync(), 'M');
    expect(File(p.join(target.path, 'country', 'geoip-tr.srs')).readAsStringSync(), 'T');
    expect(File(p.join(target.path, RuleSetInstaller.manifestName)).readAsStringSync(), manifest);
  });

  test('skips the copy when the installed manifest matches', () async {
    const manifest = 'bbb  country/geoip-tr.srs\n';
    final target = RuleSetInstaller.dirFor(tmp);
    await RuleSetInstaller(bundle: _bundle(manifest, {'country/geoip-tr.srs': 'T'}), targetDir: target).install();

    final second = _bundle(manifest, {'country/geoip-tr.srs': 'T'});
    final wrote = await RuleSetInstaller(bundle: second, targetDir: target).install();

    expect(wrote, isFalse);
    expect(second.loaded, ['${RuleSetInstaller.assetDir}/${RuleSetInstaller.manifestName}']);
  });

  test('replaces the old files when the manifest changes', () async {
    final target = RuleSetInstaller.dirFor(tmp);
    await RuleSetInstaller(
      bundle: _bundle('aaa  block/geoip-malware.srs\n', {'block/geoip-malware.srs': 'M'}),
      targetDir: target,
    ).install();

    await RuleSetInstaller(
      bundle: _bundle('ccc  country/geoip-tr.srs\n', {'country/geoip-tr.srs': 'T2'}),
      targetDir: target,
    ).install();

    expect(File(p.join(target.path, 'block', 'geoip-malware.srs')).existsSync(), isFalse);
    expect(File(p.join(target.path, 'country', 'geoip-tr.srs')).readAsStringSync(), 'T2');
  });

  test('rejects manifest paths outside the rule-set directory', () {
    expect(() => RuleSetInstaller.parseManifest('aaa  ../escape.srs'), throwsFormatException);
    expect(() => RuleSetInstaller.parseManifest('aaa  /abs.srs'), throwsFormatException);
    expect(() => RuleSetInstaller.parseManifest('aaa'), throwsFormatException);
    expect(RuleSetInstaller.parseManifest('aaa *block/x.srs\n\n'), ['block/x.srs']);
  });

  test('the core gets <workingDir>/rule-set, or nothing before directories load', () {
    final dirs = (baseDir: Directory('/b'), workingDir: Directory('/w'), tempDir: Directory('/t'));
    expect(RuleSetInstaller.corePath(dirs), p.join('/w', 'rule-set'));
    expect(RuleSetInstaller.corePath(null), '');
  });
}
