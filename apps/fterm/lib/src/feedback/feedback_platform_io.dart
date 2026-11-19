import 'dart:io' show Platform;

final RegExp _numericVersionPattern = RegExp(r'\b\d+\.\d+(?:\.\d+)?\b');

/// Returns a concise OS + numeric version label (for example `macOS 15.4`,
/// `Windows 10.0.22631`, or `Linux 6.8.0`), omitting kernel hostnames or paths.
String resolvePlatformFeedbackLabel({
  String? operatingSystem,
  String? operatingSystemVersion,
}) {
  final os = (operatingSystem ?? Platform.operatingSystem).trim().toLowerCase();
  final prettyOs = switch (os) {
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'android' => 'Android',
    'ios' => 'iOS',
    _ => 'Unknown OS',
  };
  final rawVersion = (operatingSystemVersion ?? Platform.operatingSystemVersion)
      .trim();
  final match = _numericVersionPattern.firstMatch(rawVersion);
  return match == null ? prettyOs : '$prettyOs ${match.group(0)}';
}
