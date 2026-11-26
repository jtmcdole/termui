import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show TerminalSearchHighlight;

import '../../font_loader.dart';
import '../../shader_editor/shader_editor_pane.dart';
import '../../workspace/fterm_pane_controller.dart';
import '../../workspace/fterm_workspace_controller.dart';
import '../fterm_overlays.dart';
import 'palette_command_registry.dart';
import 'palette_models.dart';
import 'palette_scrollback_jump.dart';
import 'palette_text_search.dart';

/// Top-anchored VS Code-style Command Palette supporting flat commands (`>`),
/// Quick Switcher (empty prefix), scrollback/editor line jump (`:`), and
/// multi-match text search (`%`) with live terminal canvas highlights.
final class FtermCommandPaletteOverlay extends StatefulWidget {
  /// Backing workspace coordinator.
  final FtermWorkspaceController workspace;

  /// Active theme-derived overlay colors.
  final FtermOverlayPalette palette;

  /// Whether `fterm` is running in Web/Wasm mode.
  final bool isWeb;

  /// Optional platform override for shortcut hints and OS-scoped commands.
  final TargetPlatform? platformOverride;

  /// Creates the [FtermCommandPaletteOverlay].
  const FtermCommandPaletteOverlay({
    super.key,
    required this.workspace,
    required this.palette,
    this.isWeb = false,
    this.platformOverride,
  });

  @override
  State<FtermCommandPaletteOverlay> createState() =>
      _FtermCommandPaletteOverlayState();
}

final class _FtermCommandPaletteOverlayState
    extends State<FtermCommandPaletteOverlay> {
  static const double _estimatedRowHeight = 36.0;

  late final TextEditingController _inputController;
  late final FocusNode _inputFocusNode;
  final ScrollController _listScrollController = ScrollController();

  PaletteMode _mode = .commands;
  List<PaletteItem> _items = const <PaletteItem>[];
  List<TerminalTextMatch> _activeSearchMatches = const <TerminalTextMatch>[];
  int _selectedIndex = 0;
  String? _statusHint;
  String? _errorMessage;
  bool _searchCaseSensitive = false;
  bool _searchUseRegex = false;
  bool _searchTruncated = false;

  TargetPlatform get _effectivePlatform =>
      widget.platformOverride ?? defaultTargetPlatform;

  @override
  void initState() {
    super.initState();
    widget.workspace.captureCommandPalettePreviewSnapshot();
    final initial =
        widget.workspace.consumeRequestedCommandPaletteInput() ?? '>';
    _inputController = TextEditingController(text: initial)
      ..selection = TextSelection.collapsed(offset: initial.length);
    _inputFocusNode = FocusNode(
      debugLabel: 'fterm-command-palette-input',
      onKeyEvent: _handleInputKeyEvent,
    );
    _inputController.addListener(_handleInputChanged);
    widget.workspace.chromeNotifier.addListener(_handleWorkspaceChromeChanged);
    _recomputeResults(applyPreview: false);
    if (_mode == .scrollbackJump || _mode == .textSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applySelectedPreview();
      });
    }
  }

  @override
  void dispose() {
    widget.workspace.chromeNotifier.removeListener(
      _handleWorkspaceChromeChanged,
    );
    _inputController
      ..removeListener(_handleInputChanged)
      ..dispose();
    _inputFocusNode.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  void _handleWorkspaceChromeChanged() {
    if (!mounted) return;
    final requested = widget.workspace.consumeRequestedCommandPaletteInput();
    if (requested == null || requested == _inputController.text) return;
    _inputController.value = TextEditingValue(
      text: requested,
      selection: TextSelection.collapsed(offset: requested.length),
    );
  }

  void _handleInputChanged() {
    if (!mounted) return;
    setState(() {
      _recomputeResults(applyPreview: true);
    });
  }

  KeyEventResult _handleInputKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return .ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.workspace.dismissOverlay();
      return .handled;
    }
    if (_isMoveDownEvent(key)) {
      _moveSelection(1);
      return .handled;
    }
    if (_isMoveUpEvent(key)) {
      _moveSelection(-1);
      return .handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) {
        _executeSelected();
      }
      return .handled;
    }
    return .ignored;
  }

  KeyEventResult _handleOuterKeyEvent(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      widget.workspace.dismissOverlay();
      return .handled;
    }
    return .ignored;
  }

  static bool _isCtrlOnlyPressed() {
    final kb = HardwareKeyboard.instance;
    return kb.isControlPressed &&
        !kb.isAltPressed &&
        !kb.isMetaPressed &&
        !kb.isShiftPressed;
  }

  static bool _isMoveDownEvent(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowDown ||
      (key == LogicalKeyboardKey.keyN && _isCtrlOnlyPressed());

  static bool _isMoveUpEvent(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp ||
      (key == LogicalKeyboardKey.keyP && _isCtrlOnlyPressed());

  void _moveSelection(int delta) {
    if (_items.isEmpty) return;
    setState(() {
      _selectedIndex = (_selectedIndex + delta) % _items.length;
      if (_selectedIndex < 0) _selectedIndex += _items.length;
    });
    _scrollSelectedIntoView();
    _applySelectedPreview();
  }

  void _scrollSelectedIntoView() {
    if (!_listScrollController.hasClients) return;
    final position = _listScrollController.position;
    final targetTop = _selectedIndex * _estimatedRowHeight;
    final targetBottom = targetTop + _estimatedRowHeight;
    final visibleTop = position.pixels;
    final visibleBottom = visibleTop + position.viewportDimension;
    if (targetTop < visibleTop) {
      _listScrollController.jumpTo(
        targetTop.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    } else if (targetBottom > visibleBottom) {
      _listScrollController.jumpTo(
        (targetBottom - position.viewportDimension).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    }
  }

  void _recomputeResults({required bool applyPreview}) {
    final prevMode = _mode;
    final parsed = parsePaletteInput(_inputController.text);
    _mode = parsed.mode;
    _errorMessage = null;
    _statusHint = null;
    _activeSearchMatches = const <TerminalTextMatch>[];
    _searchTruncated = false;

    if (applyPreview && prevMode == .textSearch && _mode != .textSearch) {
      widget.workspace.focusedPane?.setSearchHighlights(
        const <TerminalSearchHighlight>[],
      );
    }

    switch (_mode) {
      case .commands:
        _loadCommandResults(parsed.query);
      case .quickSwitch:
        _loadQuickSwitchResults(parsed.query);
      case .scrollbackJump:
        _loadScrollbackJumpResults(parsed.query);
      case .textSearch:
        _loadTextSearchResults(parsed.query);
    }

    _selectedIndex = 0;
    if (_listScrollController.hasClients) {
      _listScrollController.jumpTo(0);
    }
    if (applyPreview) {
      _applySelectedPreview();
    }
  }

  PaletteContext _createPaletteContext() => PaletteContext(
    workspace: widget.workspace,
    isWeb: widget.isWeb,
    platform: _effectivePlatform,
  );

  void _loadCommandResults(String query) {
    _items = queryPaletteCommands(_createPaletteContext(), query);
    if (_items.isEmpty) {
      _statusHint = 'No matching commands.';
    }
  }

  void _loadQuickSwitchResults(String query) {
    _items = queryQuickSwitchItems(_createPaletteContext(), query);
    if (_items.isEmpty) {
      _statusHint = 'No matching tabs, panes, or sessions.';
    }
  }

  void _loadScrollbackJumpResults(String query) {
    final editor = widget.workspace.focusedEditorPane;
    if (editor != null) {
      final result = resolveShaderEditorJump(editor.controller, query);
      _statusHint = result.statusHint;
      _items = _mapEditorJumpCandidates(editor, result.candidates);
      return;
    }
    final pane = widget.workspace.focusedPane;
    if (pane == null) {
      _items = const <PaletteItem>[];
      _statusHint = 'No active pane to jump in.';
      return;
    }
    final result = resolveTerminalScrollbackJump(pane, query);
    _statusHint = result.statusHint;
    _items = _mapTerminalJumpCandidates(pane, result.candidates);
  }

  List<PaletteItem> _mapTerminalJumpCandidates(
    FtermPaneController pane,
    List<ScrollbackJumpCandidate> candidates,
  ) => <PaletteItem>[
    for (final c in candidates)
      PaletteItem(
        id: c.id,
        category: c.isLandmark ? 'Jump' : 'Prompt',
        title: c.title,
        subtitle: c.subtitle,
        icon: c.isLandmark
            ? Icons.vertical_align_center
            : Icons.subdirectory_arrow_right,
        matchedTitleIndices: c.matchedIndices,
        onPreview: c.targetVirtualRow == null
            ? null
            : () => pane.scrollToVirtualRow(c.targetVirtualRow!),
        onExecute: c.targetVirtualRow == null
            ? null
            : () => pane.scrollToVirtualRow(c.targetVirtualRow!),
      ),
  ];

  List<PaletteItem> _mapEditorJumpCandidates(
    ShaderEditorPane editor,
    List<ScrollbackJumpCandidate> candidates,
  ) => <PaletteItem>[
    for (final c in candidates)
      PaletteItem(
        id: c.id,
        category: c.isLandmark ? 'Jump' : 'Line',
        title: c.title,
        subtitle: c.subtitle,
        icon: c.isLandmark ? Icons.vertical_align_center : Icons.code,
        matchedTitleIndices: c.matchedIndices,
        onPreview: c.editorLine == null
            ? null
            : () => editor.controller.jumpToLine(c.editorLine!),
        onExecute: c.editorLine == null
            ? null
            : () => editor.controller.jumpToLine(c.editorLine!),
      ),
  ];

  void _loadTextSearchResults(String query) {
    final editor = widget.workspace.focusedEditorPane;
    final pane = widget.workspace.focusedPane;
    if (editor == null && pane == null) {
      _items = const <PaletteItem>[];
      _statusHint = 'No active pane to search.';
      return;
    }
    if (query.isEmpty) {
      _items = const <PaletteItem>[];
      _statusHint = 'Type text to search active pane (Aa case, .* regex).';
      return;
    }
    final result = editor != null
        ? searchShaderEditor(
            editor.controller,
            query,
            caseSensitive: _searchCaseSensitive,
            useRegex: _searchUseRegex,
          )
        : searchTerminalPane(
            pane!,
            query,
            caseSensitive: _searchCaseSensitive,
            useRegex: _searchUseRegex,
          );
    _errorMessage = result.errorMessage;
    _activeSearchMatches = result.matches;
    _searchTruncated = result.truncated;
    if (result.errorMessage != null) {
      _items = const <PaletteItem>[];
      return;
    }
    if (result.matches.isEmpty) {
      _items = const <PaletteItem>[];
      _statusHint = 'No matches found.';
      return;
    }
    _items = editor != null
        ? _mapEditorSearchMatches(editor, result.matches)
        : _mapTerminalSearchMatches(pane!, result.matches);
  }

  List<PaletteItem> _mapTerminalSearchMatches(
    FtermPaneController pane,
    List<TerminalTextMatch> matches,
  ) => <PaletteItem>[
    for (var i = 0; i < matches.length; i++)
      _terminalMatchToItem(pane, matches[i], i),
  ];

  PaletteItem _terminalMatchToItem(
    FtermPaneController pane,
    TerminalTextMatch match,
    int index,
  ) => PaletteItem(
    id: 'search.term.$index',
    category: 'L${match.oneBasedLine}:${match.startCol + 1}',
    title: match.snippet,
    icon: Icons.search,
    matchedTitleIndices: _utf16RangeToGraphemeIndices(
      match.snippet,
      match.snippetMatchStart,
      match.snippetMatchEnd,
    ),
    onPreview: match.virtualRow == null
        ? null
        : () => pane.scrollToVirtualRow(match.virtualRow!),
    onExecute: match.virtualRow == null
        ? null
        : () => pane.scrollToVirtualRow(match.virtualRow!),
  );

  List<PaletteItem> _mapEditorSearchMatches(
    ShaderEditorPane editor,
    List<TerminalTextMatch> matches,
  ) => <PaletteItem>[
    for (var i = 0; i < matches.length; i++)
      _editorMatchToItem(editor, matches[i], i),
  ];

  PaletteItem _editorMatchToItem(
    ShaderEditorPane editor,
    TerminalTextMatch match,
    int index,
  ) {
    final line = match.editorLine;
    final col = match.editorColumn ?? 1;
    void jump() {
      if (line == null) return;
      editor.controller.jumpToLine(
        line,
        oneBasedColumn: col,
        selectionLength: match.matchLength,
      );
    }

    return PaletteItem(
      id: 'search.editor.$index',
      category: 'L${match.oneBasedLine}:$col',
      title: match.snippet,
      icon: Icons.find_in_page_outlined,
      matchedTitleIndices: _utf16RangeToGraphemeIndices(
        match.snippet,
        match.snippetMatchStart,
        match.snippetMatchEnd,
      ),
      onPreview: jump,
      onExecute: jump,
    );
  }

  void _applySelectedPreview() {
    if (_mode == .textSearch) {
      final pane = widget.workspace.focusedPane;
      if (pane != null) {
        final spans = _activeSearchMatches.isEmpty
            ? const <TerminalSearchHighlight>[]
            : buildHighlightsForMatches(_activeSearchMatches, _selectedIndex);
        pane.setSearchHighlights(spans);
      }
    }
    if (_items.isEmpty ||
        _selectedIndex < 0 ||
        _selectedIndex >= _items.length) {
      return;
    }
    _items[_selectedIndex].onPreview?.call();
  }

  void _toggleSearchCase() {
    setState(() {
      _searchCaseSensitive = !_searchCaseSensitive;
      _recomputeResults(applyPreview: true);
    });
  }

  void _toggleSearchRegex() {
    setState(() {
      _searchUseRegex = !_searchUseRegex;
      _recomputeResults(applyPreview: true);
    });
  }

  void _executeSelected() {
    if (_items.isEmpty ||
        _selectedIndex < 0 ||
        _selectedIndex >= _items.length) {
      return;
    }
    _executeItem(_items[_selectedIndex]);
  }

  void _executeItem(PaletteItem item) {
    final action = item.onExecute;
    if (action == null) return;
    final isCommandRecordable =
        _mode == .commands ||
        (_mode == .quickSwitch && !item.id.startsWith('switch.'));
    if (isCommandRecordable) {
      widget.workspace.recordRecentCommand(item.id);
    }
    widget.workspace.commitCommandPalettePreview();
    final result = action();
    if (result is Future<void>) {
      unawaited(result);
    }
    if (widget.workspace.activeOverlay == FtermOverlay.commandPalette) {
      widget.workspace.dismissOverlay();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _handleOuterKeyEvent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PaletteHeaderInput(
            mode: _mode,
            palette: p,
            controller: _inputController,
            focusNode: _inputFocusNode,
            searchCaseSensitive: _searchCaseSensitive,
            searchUseRegex: _searchUseRegex,
            onToggleCase: _toggleSearchCase,
            onToggleRegex: _toggleSearchRegex,
          ),
          Divider(height: 1, thickness: 1, color: p.border),
          _PaletteStatusBar(
            palette: p,
            mode: _mode,
            matchCount: _activeSearchMatches.length,
            selectedIndex: _selectedIndex,
            truncated: _searchTruncated,
            errorMessage: _errorMessage,
            statusHint: _statusHint,
          ),
          if (_items.isNotEmpty)
            Flexible(
              child: ListView.builder(
                key: const ValueKey('palette-results-list'),
                controller: _listScrollController,
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _items.length,
                itemBuilder: (context, index) => _buildResultEntry(index),
              ),
            ),
          Divider(height: 1, thickness: 1, color: p.border),
          _PaletteFooterBar(palette: p),
        ],
      ),
    );
  }

  Widget _buildResultEntry(int index) {
    final item = _items[index];
    final prevGroup = index > 0 ? _items[index - 1].groupLabel : null;
    final showGroupHeader =
        item.groupLabel != null &&
        item.groupLabel!.isNotEmpty &&
        item.groupLabel != prevGroup;
    final tile = _PaletteResultTile(
      item: item,
      palette: widget.palette,
      selected: index == _selectedIndex,
      onTap: () => _executeItem(item),
    );
    if (!showGroupHeader) return tile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _PaletteSectionHeader(
          label: item.groupLabel!,
          palette: widget.palette,
          topPadding: index == 0 ? 2 : 8,
        ),
        tile,
      ],
    );
  }
}

final class _PaletteHeaderInput extends StatelessWidget {
  final PaletteMode mode;
  final FtermOverlayPalette palette;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searchCaseSensitive;
  final bool searchUseRegex;
  final VoidCallback onToggleCase;
  final VoidCallback onToggleRegex;

  const _PaletteHeaderInput({
    required this.mode,
    required this.palette,
    required this.controller,
    required this.focusNode,
    required this.searchCaseSensitive,
    required this.searchUseRegex,
    required this.onToggleCase,
    required this.onToggleRegex,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: <Widget>[
          Container(
            key: const ValueKey('palette-mode-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: p.accent.withValues(alpha: 0.45)),
            ),
            child: Text(
              mode.label,
              style: TextStyle(
                color: p.accent,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                fontFamily: castPrimaryFontFamily,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('palette-input'),
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              maxLines: 1,
              style: TextStyle(
                color: p.foreground,
                fontFamily: castPrimaryFontFamily,
                fontSize: 12.5,
              ),
              cursorColor: p.accent,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                hintText: _hintForMode(mode),
                hintStyle: TextStyle(
                  color: p.muted,
                  fontFamily: castPrimaryFontFamily,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          if (mode == .textSearch) ...<Widget>[
            const SizedBox(width: 4),
            _SearchOptionChip(
              key: const ValueKey('palette-search-case-toggle'),
              label: 'Aa',
              tooltip: 'Match case',
              active: searchCaseSensitive,
              palette: p,
              onTap: onToggleCase,
            ),
            const SizedBox(width: 4),
            _SearchOptionChip(
              key: const ValueKey('palette-search-regex-toggle'),
              label: '.*',
              tooltip: 'Use regular expression',
              active: searchUseRegex,
              palette: p,
              onTap: onToggleRegex,
            ),
          ],
        ],
      ),
    );
  }

  static String _hintForMode(PaletteMode mode) => switch (mode) {
    .commands => 'Type a command...',
    .quickSwitch => 'Switch tab, pane, session, or type >, :, %...',
    .scrollbackJump => 'Line (:120, :-50, :50%) or filter prompts...',
    .textSearch => 'Search active pane text...',
  };
}

final class _SearchOptionChip extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool active;
  final FtermOverlayPalette palette;
  final VoidCallback onTap;

  const _SearchOptionChip({
    super.key,
    required this.label,
    required this.tooltip,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: active ? p.accent.withValues(alpha: 0.22) : p.surfaceAlt,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: active ? p.accent : p.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? p.accent : p.muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              fontFamily: castPrimaryFontFamily,
            ),
          ),
        ),
      ),
    );
  }
}

final class _PaletteStatusBar extends StatelessWidget {
  final FtermOverlayPalette palette;
  final PaletteMode mode;
  final int matchCount;
  final int selectedIndex;
  final bool truncated;
  final String? errorMessage;
  final String? statusHint;

  const _PaletteStatusBar({
    required this.palette,
    required this.mode,
    required this.matchCount,
    required this.selectedIndex,
    required this.truncated,
    required this.errorMessage,
    required this.statusHint,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    if (errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          errorMessage!,
          key: const ValueKey('palette-error-message'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.danger, fontSize: 11.5),
        ),
      );
    }
    if (mode == .textSearch && matchCount > 0) {
      final current = math.min(selectedIndex + 1, matchCount);
      final capSuffix = truncated ? '+' : '';
      final truncNote = truncated ? ' (capped)' : '';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(
          '$current of $matchCount$capSuffix matches$truncNote',
          key: const ValueKey('palette-match-count'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11),
        ),
      );
    }
    if (statusHint != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          statusHint!,
          key: const ValueKey('palette-status-hint'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11.5),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

final class _PaletteSectionHeader extends StatelessWidget {
  final String label;
  final FtermOverlayPalette palette;
  final double topPadding;

  const _PaletteSectionHeader({
    required this.label,
    required this.palette,
    required this.topPadding,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(12, topPadding, 12, 3),
    child: Text(
      label.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: palette.muted,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        fontFamily: castPrimaryFontFamily,
      ),
    ),
  );
}

final class _PaletteResultTile extends StatelessWidget {
  final PaletteItem item;
  final FtermOverlayPalette palette;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteResultTile({
    required this.item,
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final bg = selected ? p.accent.withValues(alpha: 0.16) : Colors.transparent;
    return InkWell(
      key: ValueKey('palette-item-${item.id}'),
      canRequestFocus: false,
      onTap: onTap,
      child: Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: <Widget>[
            if (item.icon case final icon?) ...<Widget>[
              Icon(icon, size: 14, color: selected ? p.accent : p.muted),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _HighlightedTitleText(
                    category: item.category,
                    title: item.title,
                    matchedIndices: item.matchedTitleIndices,
                    palette: p,
                  ),
                  if (item.subtitle case final sub? when sub.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: 10.5),
                      ),
                    ),
                ],
              ),
            ),
            if (item.activeBadge case final badge? when badge.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _PaletteBadgePill(
                  text: badge,
                  foreground: p.accent,
                  background: p.accent.withValues(alpha: 0.15),
                  borderColor: p.accent.withValues(alpha: 0.45),
                ),
              ),
            if (item.shortcutHint case final hint? when hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _PaletteBadgePill(
                  text: hint,
                  foreground: p.muted,
                  background: p.surfaceAlt,
                  borderColor: p.border,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _HighlightedTitleText extends StatelessWidget {
  final String? category;
  final String title;
  final List<int> matchedIndices;
  final FtermOverlayPalette palette;

  const _HighlightedTitleText({
    required this.category,
    required this.title,
    required this.matchedIndices,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final baseStyle = TextStyle(
      color: palette.foreground,
      fontFamily: castPrimaryFontFamily,
      fontSize: 12,
    );
    final matchStyle = baseStyle.copyWith(
      color: palette.accent,
      fontWeight: FontWeight.w700,
    );
    final spans = <TextSpan>[
      if (category case final cat? when cat.isNotEmpty)
        TextSpan(
          text: '$cat: ',
          style: baseStyle.copyWith(color: palette.muted),
        ),
      ..._buildTitleSpans(title, matchedIndices, baseStyle, matchStyle),
    ];
    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  static List<TextSpan> _buildTitleSpans(
    String title,
    List<int> matchedIndices,
    TextStyle baseStyle,
    TextStyle matchStyle,
  ) {
    if (matchedIndices.isEmpty || title.isEmpty) {
      return <TextSpan>[TextSpan(text: title, style: baseStyle)];
    }
    final matchSet = matchedIndices.toSet();
    final spans = <TextSpan>[];
    final buffer = StringBuffer();
    bool? currentMatched;
    var idx = 0;

    for (final ch in title.characters) {
      final isMatch = matchSet.contains(idx);
      if (currentMatched != null && currentMatched != isMatch) {
        spans.add(
          TextSpan(
            text: buffer.toString(),
            style: currentMatched ? matchStyle : baseStyle,
          ),
        );
        buffer.clear();
      }
      buffer.write(ch);
      currentMatched = isMatch;
      idx++;
    }
    if (buffer.isNotEmpty) {
      spans.add(
        TextSpan(
          text: buffer.toString(),
          style: (currentMatched ?? false) ? matchStyle : baseStyle,
        ),
      );
    }
    return spans;
  }
}

final class _PaletteBadgePill extends StatelessWidget {
  final String text;
  final Color foreground;
  final Color background;
  final Color borderColor;

  const _PaletteBadgePill({
    required this.text,
    required this.foreground,
    required this.background,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: borderColor),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: foreground,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        fontFamily: castPrimaryFontFamily,
      ),
    ),
  );
}

final class _PaletteFooterBar extends StatelessWidget {
  final FtermOverlayPalette palette;

  const _PaletteFooterBar({required this.palette});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '> commands   : line   % search   empty switch',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.muted, fontSize: 10.5),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '↑↓ nav  ↵ run  Esc close',
          style: TextStyle(color: palette.muted, fontSize: 10.5),
        ),
      ],
    ),
  );
}

List<int> _utf16RangeToGraphemeIndices(
  String text,
  int startUtf16,
  int endUtf16,
) {
  if (text.isEmpty || endUtf16 <= startUtf16) return const <int>[];
  final indices = <int>[];
  var utf16Offset = 0;
  var graphemeIndex = 0;
  for (final ch in text.characters) {
    final nextOffset = utf16Offset + ch.length;
    if (nextOffset > startUtf16 && utf16Offset < endUtf16) {
      indices.add(graphemeIndex);
    }
    utf16Offset = nextOffset;
    graphemeIndex++;
    if (utf16Offset >= endUtf16) break;
  }
  return indices;
}
