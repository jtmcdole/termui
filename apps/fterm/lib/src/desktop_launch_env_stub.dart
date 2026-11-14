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
}) => null;

/// No-op startup error reporter on Web.
void reportPlatformStartupError(String message) {}

/// No-op connect error logger on Web.
void logPlatformConnectError(Object error) {}
