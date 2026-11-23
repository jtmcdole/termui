import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'desktop_launch_env.dart';

/// Returns empty [DesktopLaunchOverrides] on Web where `dart:io` is unavailable.
DesktopLaunchOverrides readPlatformLaunchOverrides(List<String> args) =>
    const DesktopLaunchOverrides();

/// Returns `null` on Web where Cloud Run IAP relies on browser session cookies.
IapTokenProvider? buildPlatformIapTokenProvider({
  required Uri serverUri,
  String? serviceAccount,
  String? keyFilePath,
  String? gcloudPath,
}) => null;

/// Returns `null` on Web where local `gcloud` execution is unavailable.
String? probePlatformGcloudExecutable() => null;

/// No-op startup error reporter on Web.
void reportPlatformStartupError(String message) {}

/// No-op connect error logger on Web.
void logPlatformConnectError(Object error) {}

/// Unsupported secret file reader on Web.
String readPlatformSecretFileSync(String path) =>
    throw const FormatException('--token-file is not supported on Web.');

/// No-op CLI secret warning on Web.
void warnPlatformCliSecret(String flag) {}

/// Identity file path canonicalizer on Web where `dart:io` is unavailable.
String canonicalizePlatformFilePath(String rawPath) => rawPath;

/// Unsupported desktop relaunch stub on Web.
Future<bool> relaunchPlatformDesktopApp({List<String> args = const []}) async =>
    false;

/// Unsupported desktop directory reveal stub on Web.
Future<bool> openPlatformDirectory(String directoryPath) async => false;
