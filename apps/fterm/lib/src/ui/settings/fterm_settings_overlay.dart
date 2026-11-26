import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent;
import 'package:material_ui/material_ui.dart';

import '../../file_drop_bridge.dart';
import '../../workspace/fterm_workspace_controller.dart';
import '../fterm_overlays.dart';
import 'fterm_automation_settings_tab.dart';
import 'fterm_keyboard_settings_tab.dart';
import 'settings_catalog.dart';
import 'settings_primitives.dart';
import 'settings_sections.dart';
import 'settings_shader_panels.dart';

/// Blender-inspired Settings modal featuring a grouped left category rail,
/// collapsible two-column property panels, live cross-category search, and a
/// bottom-left settings action menu.
final class FtermSettingsOverlay extends StatefulWidget {
  /// Backing workspace coordinator.
  final FtermWorkspaceController workspace;

  /// Overlay color palette derived from the active terminal theme.
  final FtermOverlayPalette palette;

  /// External URL launcher invoked for release links.
  final UrlOpener onOpenUrl;

  /// Whether this host renders in Web mode.
  final bool isWeb;

  /// Optional platform override for hermetic cross-platform testing.
  final TargetPlatform? platformOverride;

  /// Creates the overhauled Settings modal overlay.
  const FtermSettingsOverlay({
    super.key,
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
    required this.isWeb,
    this.platformOverride,
  });

  @override
  State<FtermSettingsOverlay> createState() => _FtermSettingsOverlayState();
}

final class _FtermSettingsOverlayState extends State<FtermSettingsOverlay> {
  static const Duration _statusFeedbackDuration = Duration(seconds: 3);

  late final TextEditingController _searchCtrl;
  final FocusNode _overlayFocusNode = FocusNode(
    debugLabel: 'fterm-settings-overlay',
  );
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'fterm-settings-search',
  );
  final ScrollController _contentScrollCtrl = ScrollController();

  late FtermSettingsSection _activeSection;
  final Set<String> _collapsedPanels = <String>{
    ...SettingsCatalog.defaultCollapsedPanels,
  };
  String _searchQuery = '';
  bool _confirmingReset = false;
  String? _statusFeedback;
  Timer? _statusTimer;

  bool get _isSearching => _searchQuery.trim().isNotEmpty;

  bool get _supportsUpdates =>
      widget.workspace.updateViewModel.isSupportedDesktop;

  TargetPlatform _effectivePlatform(BuildContext context) =>
      widget.platformOverride ??
      (mounted ? Theme.of(context).platform : defaultTargetPlatform);

  FtermSettingsSection _resolveSection(FtermSettingsSection candidate) =>
      SettingsCatalog.resolveVisibleSection(
        candidate,
        isWeb: widget.isWeb,
        isDesktopHost: widget.workspace.isDesktopHost,
        supportsUpdates: _supportsUpdates,
      );

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    final initial =
        widget.workspace.consumeRequestedSettingsSection() ??
        widget.workspace.lastSettingsSection;
    _activeSection = _resolveSection(initial);
    widget.workspace.rememberSettingsSection(_activeSection);
    widget.workspace.chromeNotifier.addListener(_onWorkspaceChromeChanged);
  }

  @override
  void didUpdateWidget(FtermSettingsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace, widget.workspace)) {
      oldWidget.workspace.chromeNotifier.removeListener(
        _onWorkspaceChromeChanged,
      );
      widget.workspace.chromeNotifier.addListener(_onWorkspaceChromeChanged);
    }
    _consumeRequestedSection();
  }

  @override
  void dispose() {
    widget.workspace.chromeNotifier.removeListener(_onWorkspaceChromeChanged);
    _statusTimer?.cancel();
    _searchCtrl.dispose();
    _overlayFocusNode.dispose();
    _searchFocusNode.dispose();
    _contentScrollCtrl.dispose();
    super.dispose();
  }

  void _consumeRequestedSection() {
    final requested = widget.workspace.consumeRequestedSettingsSection();
    if (requested == null) return;
    _activeSection = _resolveSection(requested);
    widget.workspace.rememberSettingsSection(_activeSection);
    if (_searchQuery.isNotEmpty) {
      _searchCtrl.clear();
      _searchQuery = '';
    }
  }

  void _onWorkspaceChromeChanged() {
    if (!mounted) return;
    _consumeRequestedSection();
    setState(() {});
  }

  bool _isPanelExpanded(String panelId) => !_collapsedPanels.contains(panelId);

  void _togglePanel(String panelId) {
    setState(() {
      if (!_collapsedPanels.remove(panelId)) {
        _collapsedPanels.add(panelId);
      }
    });
  }

  void _selectSection(FtermSettingsSection section) {
    final resolved = _resolveSection(section);
    widget.workspace.rememberSettingsSection(resolved);
    setState(() {
      _activeSection = resolved;
      if (_searchQuery.isNotEmpty) {
        _searchCtrl.clear();
        _searchQuery = '';
      }
    });
    if (_contentScrollCtrl.hasClients) {
      _contentScrollCtrl.jumpTo(0);
    }
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _searchQuery = '');
    if (_searchFocusNode.hasFocus) {
      _overlayFocusNode.requestFocus();
    }
  }

  void _restoreOverlayFocus() {
    if (mounted) {
      _overlayFocusNode.requestFocus();
    }
  }

  void _showStatusFeedback(String message) {
    _statusTimer?.cancel();
    setState(() => _statusFeedback = message);
    _statusTimer = Timer(_statusFeedbackDuration, () {
      if (!mounted) return;
      setState(() => _statusFeedback = null);
    });
  }

  void _handlePrefsMenuAction(SettingsPrefsMenuAction action) {
    switch (action) {
      case .reloadFromStorage:
        widget.workspace.reloadSettingsFromStorage();
        _showStatusFeedback('Reloaded from storage');
      case .resetAllToDefaults:
        setState(() => _confirmingReset = true);
    }
    _restoreOverlayFocus();
  }

  void _confirmResetToDefaults() {
    widget.workspace.resetSettingsToDefaults();
    setState(() => _confirmingReset = false);
    _showStatusFeedback('Settings reset to defaults');
    _restoreOverlayFocus();
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return .ignored;
    final kb = HardwareKeyboard.instance;
    final platform = _effectivePlatform(context);
    final isFindChord =
        event.logicalKey == .keyF &&
        !kb.isAltPressed &&
        !kb.isShiftPressed &&
        (platform == .macOS
            ? kb.isMetaPressed && !kb.isControlPressed
            : kb.isControlPressed && !kb.isMetaPressed);
    if (isFindChord) {
      _searchFocusNode.requestFocus();
      _searchCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchCtrl.text.length,
      );
      return .handled;
    }
    if (event.logicalKey == .escape) {
      if (_confirmingReset) {
        setState(() => _confirmingReset = false);
        return .handled;
      }
      if (_isSearching) {
        _clearSearch();
        return .handled;
      }
    }
    return .ignored;
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final palette = widget.palette;
    final activeSection = _resolveSection(_activeSection);
    final visibleSections = SettingsCatalog.visibleSections(
      isWeb: widget.isWeb,
      isDesktopHost: workspace.isDesktopHost,
      supportsUpdates: _supportsUpdates,
    );
    final isSearching = _isSearching;
    final platform = _effectivePlatform(context);
    final searchResult = isSearching
        ? SettingsCatalog.search(
            _searchQuery,
            isWeb: widget.isWeb,
            isDesktopHost: workspace.isDesktopHost,
            supportsUpdates: _supportsUpdates,
            isWindows: platform == .windows,
          )
        : const SettingsSearchResult(
            sectionMatchCounts: <FtermSettingsSection, int>{},
            panelMatches: <SettingsSearchPanelMatch>[],
            totalMatches: 0,
          );

    return Focus(
      focusNode: _overlayFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          _SettingsHeaderBar(
            palette: palette,
            searchController: _searchCtrl,
            searchFocusNode: _searchFocusNode,
            searchQuery: _searchQuery,
            shortcutHint: platform == .macOS ? '⌘F' : 'Ctrl+F',
            onSearchChanged: (value) => setState(() => _searchQuery = value),
            onClearSearch: _clearSearch,
            onClose: workspace.dismissOverlay,
          ),
          Divider(height: 1, thickness: 1, color: palette.border),
          Expanded(
            child: Row(
              crossAxisAlignment: .stretch,
              children: [
                ListenableBuilder(
                  listenable: workspace.updateViewModel,
                  builder: (_, _) => BlenderSidebarRail(
                    sections: visibleSections,
                    activeSection: activeSection,
                    isSearching: isSearching,
                    searchMatchCounts: searchResult.sectionMatchCounts,
                    showUpdateDot:
                        !widget.isWeb &&
                        workspace.updateViewModel.hasActionableUpdate,
                    palette: palette,
                    onSelectSection: _selectSection,
                    onMenuAction: _handlePrefsMenuAction,
                    onMenuCanceled: _restoreOverlayFocus,
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: palette.border),
                Expanded(
                  child: Column(
                    crossAxisAlignment: .stretch,
                    children: [
                      if (_confirmingReset)
                        _ResetConfirmBanner(
                          palette: palette,
                          onCancel: () {
                            setState(() => _confirmingReset = false);
                            _restoreOverlayFocus();
                          },
                          onConfirm: _confirmResetToDefaults,
                        ),
                      Expanded(
                        child: Scrollbar(
                          controller: _contentScrollCtrl,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _contentScrollCtrl,
                            padding: const .all(14),
                            child: isSearching
                                ? _SettingsSearchResultsBody(
                                    workspace: workspace,
                                    palette: palette,
                                    onOpenUrl: widget.onOpenUrl,
                                    isWeb: widget.isWeb,
                                    platformOverride: platform,
                                    searchQuery: _searchQuery,
                                    result: searchResult,
                                    onClearSearch: _clearSearch,
                                  )
                                : _SettingsSectionContent(
                                    section: activeSection,
                                    workspace: workspace,
                                    palette: palette,
                                    onOpenUrl: widget.onOpenUrl,
                                    isWeb: widget.isWeb,
                                    platformOverride: platform,
                                    filter: SettingsPanelFilter(
                                      isPanelExpanded: _isPanelExpanded,
                                      onTogglePanel: _togglePanel,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: palette.border),
          _SettingsFooterBar(
            workspace: workspace,
            palette: palette,
            statusFeedback: _statusFeedback,
          ),
        ],
      ),
    );
  }
}

final class _SettingsSectionContent extends StatelessWidget {
  final FtermSettingsSection section;
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final UrlOpener onOpenUrl;
  final bool isWeb;
  final TargetPlatform platformOverride;
  final SettingsPanelFilter filter;

  const _SettingsSectionContent({
    required this.section,
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
    required this.isWeb,
    required this.platformOverride,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) => switch (section) {
    .interface => SettingsInterfaceSection(
      workspace: workspace,
      palette: palette,
      filter: filter,
    ),
    .themes => SettingsThemesSection(
      workspace: workspace,
      palette: palette,
      isWeb: isWeb,
      filter: filter,
    ),
    .shaders => SettingsShadersSection(
      workspace: workspace,
      palette: palette,
      isWeb: isWeb,
      filter: filter,
    ),
    .keyboard => FtermKeyboardSettingsTab(
      workspace: workspace,
      palette: palette,
      isWeb: isWeb,
      platformOverride: platformOverride,
      filter: filter,
    ),
    .shell => SettingsShellSection(
      workspace: workspace,
      palette: palette,
      platformOverride: platformOverride,
      filter: filter,
    ),
    .system => SettingsSystemSection(
      workspace: workspace,
      palette: palette,
      isWeb: isWeb,
      platformOverride: platformOverride,
      filter: filter,
    ),
    .automation => FtermAutomationSettingsTab(
      driver: workspace.automationDriver,
      palette: palette,
      filter: filter,
    ),
    .updates => SettingsUpdatesSection(
      workspace: workspace,
      palette: palette,
      onOpenUrl: onOpenUrl,
      filter: filter,
    ),
  };
}

final class _SettingsSearchResultsBody extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final UrlOpener onOpenUrl;
  final bool isWeb;
  final TargetPlatform platformOverride;
  final String searchQuery;
  final SettingsSearchResult result;
  final VoidCallback onClearSearch;

  const _SettingsSearchResultsBody({
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
    required this.isWeb,
    required this.platformOverride,
    required this.searchQuery,
    required this.result,
    required this.onClearSearch,
  });

  @override
  Widget build(BuildContext context) {
    if (result.totalMatches == 0) {
      return Center(
        child: Padding(
          padding: const .symmetric(vertical: 40),
          child: Column(
            key: const ValueKey('settings-search-empty'),
            mainAxisSize: .min,
            children: [
              Icon(
                Icons.search_off,
                size: 28,
                color: palette.muted.withValues(alpha: 0.6),
              ),
              const SizedBox(height: 8),
              Text(
                'No settings match "${searchQuery.trim()}"',
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                key: const ValueKey('settings-search-clear-empty'),
                onPressed: onClearSearch,
                child: const Text('Clear Search'),
              ),
            ],
          ),
        ),
      );
    }

    final matchWord = result.totalMatches == 1 ? 'setting' : 'settings';
    return SettingsSpacedColumn(
      key: const ValueKey('settings-search-results'),
      children: [
        Text(
          '${result.totalMatches} matching $matchWord',
          key: const ValueKey('settings-search-count'),
          style: TextStyle(color: palette.muted, fontSize: 11),
        ),
        for (final match in result.panelMatches)
          _SettingsSectionContent(
            section: match.sectionMeta.section,
            workspace: workspace,
            palette: palette,
            onOpenUrl: onOpenUrl,
            isWeb: isWeb,
            platformOverride: platformOverride,
            filter: SettingsPanelFilter(
              onlyPanelId: match.panelId,
              visibleItemIds: match.matchedItemIds,
              categoryBreadcrumb: match.sectionMeta.label,
            ),
          ),
      ],
    );
  }
}

final class _SettingsHeaderBar extends StatelessWidget {
  final FtermOverlayPalette palette;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchQuery;
  final String shortcutHint;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onClose;

  const _SettingsHeaderBar({
    required this.palette,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchQuery,
    required this.shortcutHint,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const .fromLTRB(14, 9, 10, 9),
    child: Row(
      children: [
        Text(
          'Settings',
          style: TextStyle(
            color: palette.foreground,
            fontWeight: .w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Align(
            alignment: .centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: SizedBox(
                height: 28,
                child: TextField(
                  key: const ValueKey('settings-search-field'),
                  controller: searchController,
                  focusNode: searchFocusNode,
                  onChanged: onSearchChanged,
                  style: TextStyle(color: palette.foreground, fontSize: 11.5),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: palette.surfaceAlt,
                    hintText: 'Search settings…',
                    hintStyle: TextStyle(
                      color: palette.muted.withValues(alpha: 0.75),
                      fontSize: 11,
                    ),
                    contentPadding: const .symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 14,
                      color: palette.muted,
                    ),
                    prefixIconConstraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            key: const ValueKey('settings-search-clear'),
                            tooltip: 'Clear search (Esc)',
                            padding: .zero,
                            icon: Icon(
                              Icons.close,
                              size: 14,
                              color: palette.muted,
                            ),
                            onPressed: onClearSearch,
                          )
                        : Padding(
                            padding: const .only(right: 8),
                            child: Center(
                              widthFactor: 1,
                              child: Text(
                                shortcutHint,
                                style: TextStyle(
                                  color: palette.muted.withValues(alpha: 0.65),
                                  fontSize: 9.5,
                                ),
                              ),
                            ),
                          ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 26,
                      maxHeight: 28,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: .circular(5),
                      borderSide: BorderSide(color: palette.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: .circular(5),
                      borderSide: BorderSide(color: palette.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: .circular(5),
                      borderSide: BorderSide(color: palette.accent, width: 1.2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const ValueKey('settings-close-button'),
          onPressed: onClose,
          icon: Icon(Icons.close, size: 16, color: palette.muted),
          tooltip: 'Close (Esc)',
          padding: .zero,
          constraints: const BoxConstraints.tightFor(width: 26, height: 26),
        ),
      ],
    ),
  );
}

final class _ResetConfirmBanner extends StatelessWidget {
  final FtermOverlayPalette palette;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _ResetConfirmBanner({
    required this.palette,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('settings-reset-confirm-banner'),
    padding: const .symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
      color: palette.danger.withValues(alpha: 0.14),
      border: Border(
        bottom: BorderSide(color: palette.danger.withValues(alpha: 0.5)),
      ),
    ),
    child: Wrap(
      alignment: .spaceBetween,
      crossAxisAlignment: .center,
      spacing: 8,
      runSpacing: 6,
      children: [
        Row(
          mainAxisSize: .min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: palette.danger),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Reset all settings to factory defaults? '
                '(Relay credentials and automation settings are preserved.)',
                style: TextStyle(color: palette.foreground, fontSize: 11.5),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: .center,
          children: [
            TextButton(
              key: const ValueKey('settings-reset-cancel'),
              onPressed: onCancel,
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('settings-reset-confirm'),
              onPressed: onConfirm,
              style: FilledButton.styleFrom(
                backgroundColor: palette.danger,
                foregroundColor: settingsContrastingOnColor(palette.danger),
              ),
              child: const Text('Reset All'),
            ),
          ],
        ),
      ],
    ),
  );
}

final class _SettingsFooterBar extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final String? statusFeedback;

  const _SettingsFooterBar({
    required this.workspace,
    required this.palette,
    required this.statusFeedback,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const .symmetric(horizontal: 14, vertical: 8),
    child: Wrap(
      alignment: .spaceBetween,
      crossAxisAlignment: .center,
      spacing: 8,
      runSpacing: 6,
      children: [
        Text(
          statusFeedback ?? 'Changes save automatically',
          key: const ValueKey('settings-status-feedback'),
          overflow: .ellipsis,
          style: TextStyle(
            color: statusFeedback != null ? palette.accent : palette.muted,
            fontSize: 10.5,
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: .center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('settings-open-about'),
              onPressed: () => workspace.setOverlay(.about),
              icon: const Icon(Icons.info_outline, size: 14),
              label: const Text('About'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('settings-open-connect'),
              onPressed: () => workspace.setOverlay(.connect),
              icon: const Icon(Icons.cloud_outlined, size: 14),
              label: const Text('Relay Connection…'),
            ),
            FilledButton(
              key: const ValueKey('settings-done'),
              onPressed: workspace.dismissOverlay,
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    ),
  );
}
