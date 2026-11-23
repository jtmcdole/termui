import 'dart:async';
import 'dart:io' show Platform;

import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_flutter/termui_flutter.dart';

import 'file_drop_bridge.dart';

/// Creates a no-op [FileDropBridge] on native desktop (`dart:io`) platforms
/// where drag-and-drop uses OS pasteboard hooks rather than DOM listeners.
FileDropBridge createPlatformFileDropBridge({
  required void Function(bool isDraggingOver) onDragHoverChanged,
  required void Function(List<DroppedFileSource> files) onFilesDropped,
}) => const _NoopIoFileDropBridge();

/// Opens [url] (`http`, `https`, or `mailto`) via [DefaultTerminalService],
/// delegating to the host OS launcher (`open` on macOS, `xdg-open` on Linux,
/// `rundll32` on Windows), or returns early when running under `FLUTTER_TEST`.
void openPlatformExternalUrl(Uri url) {
  if (Platform.environment['FLUTTER_TEST'] == 'true') return;
  unawaited(const DefaultTerminalService().openUrl(url.toString()));
}

/// No-op URL fragment scrubber on native desktop (`dart:io`) platforms.
void scrubPlatformUrlFragment() {}

/// No-op initial hash token reader on native desktop (`dart:io`) platforms.
String consumePlatformInitialHashToken() => '';

/// Returns [fallback] unchanged on native desktop (`dart:io`) platforms.
Uri resolvePlatformLaunchBaseUri(Uri fallback) => fallback;

final class _NoopIoFileDropBridge implements FileDropBridge {
  const _NoopIoFileDropBridge();

  @override
  void dispose() {}
}
