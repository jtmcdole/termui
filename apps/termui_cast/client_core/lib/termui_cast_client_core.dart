/// Pure-Dart client transport, repository, and headless terminal port primitives.
library;

export 'package:termui_cast_protocol/termui_cast_protocol.dart'
    show IapTokenProvider, parseCastWebSocketUri;

export 'src/cast_client_repository.dart';
export 'src/file_upload_coordinator.dart';
export 'src/models.dart';
export 'src/remote_terminal_port.dart';
export 'src/session_slot.dart' show DirtyCellSpan;
export 'src/terminal_theme_settings.dart';
export 'src/transport/ws_client_transport.dart';
export 'src/workspace_buffer_compositor.dart' show WorkspaceBufferCompositor;
