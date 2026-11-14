/// Pure-Dart client transport, repository, HSM view model, and SceneManager UI.
library;

export 'package:termui_cast_protocol/termui_cast_protocol.dart'
    show IapTokenProvider, parseCastWebSocketUri;

export 'src/cast_client_repository.dart';
export 'src/cast_workspace_view_model.dart';
export 'src/file_upload_coordinator.dart';
export 'src/models.dart';
export 'src/remote_terminal_port.dart';
export 'src/session_slot.dart' show DirtyCellSpan;
export 'src/session_tab_strip.dart';
export 'src/terminal_theme_settings.dart';
export 'src/transport/ws_client_transport.dart';
export 'src/ui/cast_scene_controller.dart';
export 'src/ui/chords_help_dialog.dart';
export 'src/ui/connection_prompt_dialog.dart';
export 'src/ui/dialog_theme.dart'
    show WorkspaceChromeScope, WorkspaceChromeTheme;
export 'src/ui/dock_gesture_tracker.dart';
export 'src/ui/dock_tab_layout.dart';
export 'src/ui/file_upload_dialog.dart';
export 'src/ui/remote_pty_scene_renderer.dart';
export 'src/ui/rename_tab_dialog.dart';
export 'src/ui/session_dock_bar.dart';
export 'src/ui/settings_dialog.dart';
export 'src/ui/stats_for_nerds_dialog.dart';
export 'src/ui/view_model_scene_renderer.dart';
export 'src/workspace_buffer_compositor.dart' show WorkspaceBufferCompositor;
