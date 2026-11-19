import 'dart:io' show Directory, File, FileSystemException, Platform;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Saves a feedback screenshot PNG into a user-writable directory (`~/Downloads`
/// when present, otherwise [Directory.systemTemp]), avoiding read-only app
/// bundle working directories (such as `/` on macOS Finder launches).
Future<String?> savePlatformFeedbackScreenshot(
  String basename,
  Uint8List bytes, {
  Map<String, String>? environment,
  Directory? tempDirectory,
}) async {
  final safeName = p.basename(basename.trim());
  if (safeName.isEmpty || safeName == '.' || safeName == '..') return null;

  final candidates = resolveFeedbackScreenshotDirectories(
    environment: environment,
    tempDirectory: tempDirectory,
  );
  for (final dir in candidates) {
    try {
      if (!dir.existsSync()) continue;
      final outPath = p.join(dir.path, safeName);
      await File(outPath).writeAsBytes(bytes, flush: true);
      return outPath;
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

/// Returns ordered candidate directories for desktop feedback screenshots:
/// `~/Downloads` first (if a home directory is configured), then system temp.
List<Directory> resolveFeedbackScreenshotDirectories({
  Map<String, String>? environment,
  Directory? tempDirectory,
}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME']?.trim().isNotEmpty == true
      ? env['HOME']!.trim()
      : env['USERPROFILE']?.trim();
  final temp = tempDirectory ?? Directory.systemTemp;
  return [
    if (home != null && home.isNotEmpty) Directory(p.join(home, 'Downloads')),
    temp,
  ];
}
