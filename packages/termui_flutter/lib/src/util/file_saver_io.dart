import 'package:termui/perf/fs_locator.dart';

/// Saves the given [bytes] to a file with the specified [basename].
Future<String?> saveFile(String basename, List<int> bytes) async {
  final fs = getDefaultFileSystem();
  final path = fs.path.join(fs.currentDirectory.path, basename);
  final file = fs.file(path);
  await file.writeAsBytes(bytes);
  return basename;
}
