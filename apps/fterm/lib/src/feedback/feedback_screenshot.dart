import 'dart:typed_data';

import 'feedback_screenshot_stub.dart'
    if (dart.library.io) 'feedback_screenshot_io.dart'
    as platform;

/// Saves a captured feedback PNG [bytes] with filename [basename] to a
/// user-writable location (desktop `~/Downloads` or system temp; browser
/// download on Web), returning the saved local path or filename.
Future<String?> saveFeedbackScreenshot(String basename, Uint8List bytes) =>
    platform.savePlatformFeedbackScreenshot(basename, bytes);
