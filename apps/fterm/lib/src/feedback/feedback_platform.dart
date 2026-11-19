import 'feedback_platform_stub.dart'
    if (dart.library.io) 'feedback_platform_io.dart'
    as platform;

/// Returns a compact client OS + version label for GitHub issue reports
/// (for example `macOS 15.4`, `Windows 10.0.22631`, `Linux 6.8.0`, or `Web`).
String resolveFeedbackPlatformLabel() =>
    platform.resolvePlatformFeedbackLabel();
