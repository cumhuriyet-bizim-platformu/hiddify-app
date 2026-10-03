import 'dart:io';

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
  /// already current.
  Future<bool> install() async {
    final manifest = await bundle.loadString('$assetDir/$manifestName', cache: false);
    final installedManifest = File(p.join(targetDir.path, manifestName));
    if (await installedManifest.exists() && await installedManifest.readAsString() == manifest) {
      return false;
    }
    final files = parseManifest(manifest);
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);
    for (final relative in files) {
      final data = await bundle.load('$assetDir/$relative');
      final out = File(p.joinAll([targetDir.path, ...p.posix.split(relative)]));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    await installedManifest.writeAsString(manifest, flush: true);
    return true;
  }

  /// The relative paths listed in [manifest]. Throws a [FormatException] for a
  /// malformed line or a path that is absolute or leaves the directory.
  static List<String> parseManifest(String manifest) {
    final files = <String>[];
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
      files.add(relative);
    }
    return files;
  }
}
