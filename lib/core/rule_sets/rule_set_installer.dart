import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:path/path.dart' as p;

/// Copies the sing-box rule-sets bundled under [assetDir] to a directory the
/// core can read, so the core never downloads a rule-set.
///
/// The bundle holds `manifest.txt` with one `<sha256>  <relative path>` line
/// per file (written by `make rule-set-assets`). The copy is redone whenever
/// the bundled manifest differs from the installed one, that is after an app
/// update that changed the rule-sets.
class RuleSetInstaller {
  RuleSetInstaller({required this.bundle, required this.targetDir});

  static const assetDir = 'assets/rule-set';
  static const manifestName = 'manifest.txt';

  final AssetBundle bundle;
  final Directory targetDir;

  /// The rule-set directory under the core's working directory. On iOS the
  /// working directory is the app-group container the tunnel extension reads.
  static Directory dirFor(Directory workingDir) => Directory(p.join(workingDir.path, 'rule-set'));

  /// The value sent to the core as `rule-set-dir`; empty until the app
  /// directories are known, in which case the core uses no rule-sets.
  static String corePath(Directories? dirs) => dirs == null ? '' : dirFor(dirs.workingDir).path;

  /// Copies the bundled files. Returns false when the installed copy is
  /// already current and intact. When the manifests match, each listed file is
  /// checked against its sha256 and only missing or mismatched files are
  /// copied again; a changed manifest replaces the whole directory.
  Future<bool> install() async {
    final manifest = await bundle.loadString('$assetDir/$manifestName', cache: false);
    final entries = parseEntries(manifest);
    final installedManifest = File(p.join(targetDir.path, manifestName));
    final sameManifest = await installedManifest.exists() && await installedManifest.readAsString() == manifest;
    final List<String> toCopy;
    if (sameManifest) {
      toCopy = [
        for (final e in entries)
          if (!await _intact(e.path, e.sha256)) e.path,
      ];
      if (toCopy.isEmpty) return false;
    } else {
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      toCopy = [for (final e in entries) e.path];
    }
    await targetDir.create(recursive: true);
    for (final relative in toCopy) {
      final data = await bundle.load('$assetDir/$relative');
      final out = _file(relative);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    await installedManifest.writeAsString(manifest, flush: true);
    return true;
  }

  File _file(String relative) => File(p.joinAll([targetDir.path, ...p.posix.split(relative)]));

  /// True when the installed file exists and its sha256 equals [expected]. An
  /// unparsable [expected] never matches, so the file is copied again.
  Future<bool> _intact(String relative, String expected) async {
    final file = _file(relative);
    try {
      if (!await file.exists()) return false;
      return sha256.convert(await file.readAsBytes()).toString() == expected.toLowerCase();
    } on FileSystemException {
      return false;
    }
  }

  /// The `(sha256, path)` pairs listed in [manifest]; see [parseManifest] for
  /// the path rules. The hash is not validated here.
  static List<({String sha256, String path})> parseEntries(String manifest) {
    final entries = <({String sha256, String path})>[];
    for (final line in manifest.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length != 2) {
        throw FormatException('bad rule-set manifest line', line);
      }
      final relative = parts[1].startsWith('*') ? parts[1].substring(1) : parts[1];
      if (p.posix.isAbsolute(relative) || p.posix.normalize(relative) != relative || relative.startsWith('..')) {
        throw FormatException('bad rule-set path', relative);
      }
      entries.add((sha256: parts[0], path: relative));
    }
    return entries;
  }

  /// The relative paths listed in [manifest]. Throws a [FormatException] for a
  /// malformed line or a path that is absolute or leaves the directory.
  static List<String> parseManifest(String manifest) => [for (final e in parseEntries(manifest)) e.path];
}
