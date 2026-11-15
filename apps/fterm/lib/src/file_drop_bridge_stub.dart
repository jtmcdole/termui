import 'package:termui_cast_client_core/termui_cast_client_core.dart';

import 'file_drop_bridge.dart';

/// Creates a no-op [FileDropBridge] on unsupported/fallback platforms.
FileDropBridge createPlatformFileDropBridge({
  required void Function(bool isDraggingOver) onDragHoverChanged,
  required void Function(List<DroppedFileSource> files) onFilesDropped,
}) => const _NoopFileDropBridge();

/// No-op external URL launcher on unsupported/fallback platforms.
void openPlatformExternalUrl(Uri url) {}

/// No-op URL fragment scrubber on unsupported/fallback platforms.
void scrubPlatformUrlFragment() {}

/// No-op initial hash token reader on unsupported/fallback platforms.
String consumePlatformInitialHashToken() => '';

final class _NoopFileDropBridge implements FileDropBridge {
  const _NoopFileDropBridge();

  @override
  void dispose() {}
}
