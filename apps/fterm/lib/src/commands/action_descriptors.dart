import 'package:material_ui/material_ui.dart' show Icons;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show DockPosition;

import '../workspace/fterm_pane_controller.dart';
import '../workspace/fterm_workspace_controller.dart';
import '../workspace/local_host_driver.dart' show LocalShareState;
import '../workspace/split_tree_model.dart' show FocusDirection, SplitAxis;
import 'fterm_descriptor_models.dart';
import 'shortcut_catalog.dart';

/// Declarative Workspace, Pane, Tab, and Interface actions in canonical
/// Command Palette ordering.
final List<FtermActionDescriptor> workspaceAndTabActionDescriptors =
    List<FtermActionDescriptor>.unmodifiable(<FtermActionDescriptor>[
      FtermActionDescriptor(
        id: 'workspace.new_local_shell',
        category: 'Workspace',
        title: 'New Local Shell',
        shortcut: FtermShortcuts.newLocalShell,
        keywords: 'new tab terminal local shell pty spawn',
        icon: Icons.add_box_outlined,
        visibility: .localDesktopShell,
        execute: (ws) => ws.openLocalShellTab(),
      ),
      FtermActionDescriptor(
        id: 'workspace.sessions_picker',
        category: 'Workspace',
        title: 'Sessions & Shells',
        shortcut: FtermShortcuts.sessionsPicker,
        keywords: 'session picker shells local remote switch connect',
        icon: Icons.terminal,
        execute: (ws) => ws.setOverlay(.sessionPicker),
      ),
      FtermActionDescriptor(
        id: 'pane.split_right',
        category: 'Pane',
        title: 'Split Right',
        shortcut: FtermShortcuts.splitRight,
        keywords: 'split horizontal side by side pane right',
        icon: Icons.vertical_split,
        execute: (ws) => ws.splitFocusedPane(SplitAxis.horizontal),
      ),
      FtermActionDescriptor(
        id: 'pane.split_down',
        category: 'Pane',
        title: 'Split Down',
        shortcut: FtermShortcuts.splitDown,
        keywords: 'split vertical stacked pane down bottom',
        icon: Icons.horizontal_split,
        execute: (ws) => ws.splitFocusedPane(SplitAxis.vertical),
      ),
      FtermActionDescriptor(
        id: 'pane.focus_left',
        category: 'Pane',
        title: 'Focus Left',
        shortcut: FtermShortcuts.focusLeft,
        keywords: 'pane navigate move focus left arrow',
        icon: Icons.arrow_back,
        execute: (ws) => ws.focusDirection(FocusDirection.left),
      ),
      FtermActionDescriptor(
        id: 'pane.focus_down',
        category: 'Pane',
        title: 'Focus Down',
        shortcut: FtermShortcuts.focusDown,
        keywords: 'pane navigate move focus down arrow',
        icon: Icons.arrow_downward,
        execute: (ws) => ws.focusDirection(FocusDirection.down),
      ),
      FtermActionDescriptor(
        id: 'pane.focus_up',
        category: 'Pane',
        title: 'Focus Up',
        shortcut: FtermShortcuts.focusUp,
        keywords: 'pane navigate move focus up arrow',
        icon: Icons.arrow_upward,
        execute: (ws) => ws.focusDirection(FocusDirection.up),
      ),
      FtermActionDescriptor(
        id: 'pane.focus_right',
        category: 'Pane',
        title: 'Focus Right',
        shortcut: FtermShortcuts.focusRight,
        keywords: 'pane navigate move focus right arrow',
        icon: Icons.arrow_forward,
        execute: (ws) => ws.focusDirection(FocusDirection.right),
      ),
      FtermActionDescriptor(
        id: 'pane.toggle_zoom',
        category: 'Pane',
        title: 'Toggle Zoom',
        shortcut: FtermShortcuts.toggleZoom,
        activeBadgeBuilder: (ws) =>
            (ws.activeSplitTree?.isZoomed ?? false) ? 'Zoomed' : null,
        keywords: 'pane zoom fullscreen maximize expand tmux',
        icon: Icons.zoom_out_map,
        execute: (ws) => ws.toggleZoom(),
      ),
      FtermActionDescriptor(
        id: 'pane.close',
        category: 'Pane',
        title: 'Close Pane',
        shortcut: FtermShortcuts.closePane,
        keywords: 'close pane tab exit kill',
        icon: Icons.close,
        execute: (ws) => ws.closePane(),
      ),
      FtermActionDescriptor(
        id: 'tab.next',
        category: 'Tab',
        title: 'Next Tab',
        shortcut: FtermShortcuts.nextTab,
        keywords: 'tab switch cycle next forward',
        icon: Icons.tab,
        execute: (ws) => ws.cycleTab(),
      ),
      FtermActionDescriptor(
        id: 'tab.previous',
        category: 'Tab',
        title: 'Previous Tab',
        shortcut: FtermShortcuts.previousTab,
        keywords: 'tab switch cycle previous prev back',
        icon: Icons.tab,
        execute: (ws) => ws.cycleTab(reverse: true),
      ),
      FtermActionDescriptor(
        id: 'tab.rename',
        category: 'Tab',
        title: 'Rename Tab',
        shortcut: FtermShortcuts.renameTab,
        keywords: 'tab rename title pin label',
        icon: Icons.edit,
        execute: (ws) => ws.setOverlay(.rename),
      ),
      FtermActionDescriptor(
        id: 'pane.toggle_relay_share',
        category: 'Workspace',
        title: 'Toggle Relay Share',
        shortcut: FtermShortcuts.togglePaneShare,
        activeBadgeBuilder: (ws) => _relayShareBadge(ws.focusedPane),
        keywords: 'relay share broadcast cast live stream',
        icon: Icons.cast,
        visibility: .localDesktopShell,
        execute: (ws) => ws.togglePaneShare(),
      ),
      FtermActionDescriptor(
        id: 'interface.cycle_dock_position',
        category: 'Interface',
        title: 'Cycle Tab Bar Position',
        subtitleBuilder: (ws) => 'Current: ${_dockLabel(ws.dockPosition)}',
        shortcut: FtermShortcuts.cycleDockPosition,
        keywords: 'tab bar dock position cycle top left hidden',
        icon: Icons.view_quilt_outlined,
        execute: (ws) => ws.cycleDockPosition(),
      ),
    ]);

/// Declarative Appearance actions (font zoom controls and wallpaper shortcut)
/// in canonical Command Palette ordering.
final List<FtermActionDescriptor> appearanceActionDescriptors =
    List<FtermActionDescriptor>.unmodifiable(<FtermActionDescriptor>[
      FtermActionDescriptor(
        id: 'appearance.font_increase',
        category: 'Appearance',
        title: 'Increase Font Size',
        subtitleBuilder: _currentFontSizeSubtitle,
        shortcut: FtermShortcuts.fontIncrease,
        keywords: 'font size zoom in larger text typography',
        icon: Icons.text_increase,
        execute: (ws) => ws.adjustFontSize(1.0),
      ),
      FtermActionDescriptor(
        id: 'appearance.font_decrease',
        category: 'Appearance',
        title: 'Decrease Font Size',
        subtitleBuilder: _currentFontSizeSubtitle,
        shortcut: FtermShortcuts.fontDecrease,
        keywords: 'font size zoom out smaller text typography',
        icon: Icons.text_decrease,
        execute: (ws) => ws.adjustFontSize(-1.0),
      ),
      FtermActionDescriptor(
        id: 'appearance.font_reset',
        category: 'Appearance',
        title: 'Reset Font Size',
        subtitleBuilder: _currentFontSizeSubtitle,
        shortcut: FtermShortcuts.fontReset,
        keywords: 'font size zoom reset default typography',
        icon: Icons.format_size,
        execute: (ws) => ws.resetFontSize(),
      ),
      FtermActionDescriptor(
        id: 'appearance.wallpaper_set',
        category: 'Appearance',
        title: 'Set Wallpaper...',
        subtitleBuilder: (ws) => ws.backgroundImagePath ?? 'None',
        keywords: 'wallpaper background image png jpeg webp picture set',
        icon: Icons.wallpaper_outlined,
        execute: (ws) => ws.openSettingsOverlay(initialSection: .themes),
      ),
    ]);

/// Declarative Shader control actions in canonical Command Palette ordering.
final List<FtermActionDescriptor> shaderActionDescriptors =
    List<FtermActionDescriptor>.unmodifiable(<FtermActionDescriptor>[
      FtermActionDescriptor(
        id: 'shader.emergency_stop',
        category: 'Shader',
        title: 'Emergency Stop Shaders',
        dynamicTitleBuilder: (ws) => ws.shadersEmergencyStopped
            ? 'Resume Shaders'
            : 'Emergency Stop Shaders',
        shortcut: FtermShortcuts.emergencyStopShaders,
        activeBadgeBuilder: (ws) =>
            ws.shadersEmergencyStopped ? 'Stopped' : null,
        keywords: 'shader emergency stop resume bypass panic gpu',
        icon: Icons.stop_circle_outlined,
        dynamicIconBuilder: (ws) => ws.shadersEmergencyStopped
            ? Icons.play_arrow
            : Icons.stop_circle_outlined,
        execute: (ws) => ws.toggleShaderEmergencyStop(),
      ),
      FtermActionDescriptor(
        id: 'shader.reload',
        category: 'Shader',
        title: 'Reload Shaders',
        shortcut: FtermShortcuts.reloadShaders,
        keywords: 'shader reload recompile refresh glsl',
        icon: Icons.refresh,
        execute: (ws) => ws.reloadShaders(),
      ),
      FtermActionDescriptor(
        id: 'shader.open_folder',
        category: 'Shader',
        title: 'Open Shaders Folder',
        keywords: 'shader folder directory reveal explorer finder glsl',
        icon: Icons.folder_open,
        visibility: .localDesktopShell,
        execute: (ws) => ws.openShadersFolder(),
      ),
      FtermActionDescriptor(
        id: 'shader.new_editor_tab',
        category: 'Shader',
        title: 'New Shader Editor Tab',
        shortcut: FtermShortcuts.openShaderEditorTab,
        keywords: 'shader editor new glsl live code tab',
        icon: Icons.code,
        execute: (ws) => ws.openShaderEditorTab(),
      ),
    ]);

/// Declarative System, Settings storage, Diagnostics, and modal Overlay
/// actions in canonical Command Palette ordering.
final List<FtermActionDescriptor> systemAndOverlayActionDescriptors =
    List<FtermActionDescriptor>.unmodifiable(<FtermActionDescriptor>[
      FtermActionDescriptor(
        id: 'settings.reload_storage',
        category: 'Settings',
        title: 'Reload from Storage',
        keywords: 'settings reload disk storage json refresh config',
        icon: Icons.refresh,
        execute: (ws) => ws.reloadSettingsFromStorage(),
      ),
      FtermActionDescriptor(
        id: 'system.check_updates',
        category: 'System',
        title: 'Check for Updates',
        keywords: 'update check version release upgrade github',
        icon: Icons.system_update_alt,
        visibility: .updatesSupported,
        execute: (ws) {
          ws.openSettingsOverlay(initialSection: .updates);
          return ws.updateViewModel.checkForUpdates();
        },
      ),
      FtermActionDescriptor(
        id: 'diagnostics.toggle_trace_recording',
        category: 'System',
        title: 'Toggle Trace Recording',
        shortcut: FtermShortcuts.toggleTraceRecording,
        activeBadgeBuilder: (ws) => ws.isRecordingTrace ? 'Recording' : null,
        keywords:
            'trace recording perfetto performance profile diagnostics capture',
        icon: Icons.fiber_manual_record,
        visibility: .desktopOnly,
        execute: (ws) => ws.toggleTraceRecording(),
      ),
      FtermActionDescriptor(
        id: 'overlay.connect',
        category: 'Workspace',
        title: 'Relay Connection',
        keywords: 'relay connect server url token credentials iap',
        icon: Icons.cloud_outlined,
        execute: (ws) => ws.setOverlay(.connect),
      ),
      FtermActionDescriptor(
        id: 'overlay.stats',
        category: 'System',
        title: 'Session Stats',
        shortcut: FtermShortcuts.openStats,
        keywords: 'stats telemetry network audio metrics diagnostics',
        icon: Icons.analytics_outlined,
        execute: (ws) => ws.setOverlay(.stats),
      ),
      FtermActionDescriptor(
        id: 'overlay.help',
        category: 'Help',
        title: 'Keyboard Shortcuts',
        shortcut: FtermShortcuts.openHelp,
        keywords: 'help shortcuts keybindings chords reference',
        icon: Icons.keyboard_outlined,
        execute: (ws) => ws.setOverlay(.help),
      ),
      FtermActionDescriptor(
        id: 'overlay.whats_new',
        category: 'Help',
        title: "What's New",
        keywords: 'whats new release notes highlights changelog showcase',
        icon: Icons.auto_awesome,
        execute: (ws) => ws.openWhatsNew(),
      ),
      FtermActionDescriptor(
        id: 'overlay.about',
        category: 'Help',
        title: 'About fterm',
        shortcut: FtermShortcuts.openAbout,
        keywords: 'about version licenses credits fterm',
        icon: Icons.info_outline,
        execute: (ws) => ws.setOverlay(.about),
      ),
    ]);

/// Complete immutable catalog of all static `fterm` action descriptors across
/// every category.
final List<FtermActionDescriptor> allActionDescriptors =
    List<FtermActionDescriptor>.unmodifiable(<FtermActionDescriptor>[
      ...workspaceAndTabActionDescriptors,
      ...appearanceActionDescriptors,
      ...shaderActionDescriptors,
      ...systemAndOverlayActionDescriptors,
    ]);

final Map<String, FtermActionDescriptor> _actionDescriptorsById =
    Map<String, FtermActionDescriptor>.unmodifiable(
      <String, FtermActionDescriptor>{
        for (final descriptor in allActionDescriptors)
          descriptor.id: descriptor,
      },
    );

/// Looks up a static [FtermActionDescriptor] by its stable [id], returning
/// `null` when no action matches.
FtermActionDescriptor? actionDescriptorById(String id) =>
    _actionDescriptorsById[id];

String? _relayShareBadge(FtermPaneController? pane) {
  if (pane == null || !pane.isLocal) return null;
  return switch (pane.shareSnapshot.state) {
    LocalShareState.live => 'Live',
    LocalShareState.connecting => 'Connecting',
    LocalShareState.unshared || LocalShareState.error => null,
  };
}

String _dockLabel(DockPosition pos) => switch (pos) {
  .top => 'Top',
  .left => 'Left',
  .hidden => 'Hidden',
};

String _currentFontSizeSubtitle(FtermWorkspaceController ws) {
  final size = ws.effectiveFontSize;
  final formatted = size == size.roundToDouble()
      ? '${size.toInt()} pt'
      : '${size.toStringAsFixed(1)} pt';
  return 'Current: $formatted';
}
