import 'dart:typed_data';

import 'package:termui_flutter/termui_flutter.dart' show saveFile;

/// Triggers a browser download of the feedback screenshot PNG on Web.
Future<String?> savePlatformFeedbackScreenshot(
  String basename,
  Uint8List bytes,
) => saveFile(basename, bytes);
