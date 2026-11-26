import 'dart:async' show FutureOr;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:material_ui/material_ui.dart' show IconData;

/// Active input mode inside the `fterm` Command Palette.
enum PaletteMode {
  /// Empty prefix: switch tabs, split panes, remote sessions, or recent actions.
  quickSwitch('', 'Quick Switch'),

  /// `>` prefix: flat fuzzy-searchable command catalog.
  commands('>', 'Commands'),

  /// `:` prefix: jump to scrollback lines, percentages, or OSC 133 prompts.
  scrollbackJump(':', 'Go to Line'),

  /// `%` prefix: multi-match terminal scrollback or shader editor text search.
  textSearch('%', 'Search');

  /// Leading prefix character activating this mode (`''` for [quickSwitch]).
  final String prefix;

  /// Human-readable mode badge label displayed in the palette header.
  final String label;

  const PaletteMode(this.prefix, this.label);
}

/// Parsed mode and stripped query returned by [parsePaletteInput].
typedef ParsedPaletteInput = ({PaletteMode mode, String query});

/// Parses [rawInput] into a [PaletteMode] and mode-stripped query string.
///
/// Leading whitespace before a mode prefix (`>`, `:`, `%`) is ignored. For
/// `%` text search, leading whitespace after `%` is trimmed while trailing
/// whitespace is preserved so users can search for trailing spaces intentionally.
ParsedPaletteInput parsePaletteInput(String rawInput) {
  final trimmedLeft = rawInput.trimLeft();
  if (trimmedLeft.isEmpty) {
    return (mode: .quickSwitch, query: '');
  }
  return switch (trimmedLeft[0]) {
    '>' => (mode: .commands, query: trimmedLeft.substring(1).trim()),
    ':' => (mode: .scrollbackJump, query: trimmedLeft.substring(1).trim()),
    '%' => (mode: .textSearch, query: trimmedLeft.substring(1).trimLeft()),
    _ => (mode: .quickSwitch, query: rawInput.trim()),
  };
}

/// Immutable row entry rendered inside the Command Palette results list.
final class PaletteItem {
  /// Stable unique identifier used for selection tracking and session MRU.
  final String id;

  /// Optional leading category label rendered before [title] (e.g. `Theme`).
  final String? category;

  /// Primary display label matched and highlighted against user queries.
  final String title;

  /// Optional secondary metadata line (e.g. tab context or current value).
  final String? subtitle;

  /// Optional right-aligned keyboard shortcut pill (e.g. `Ctrl+\ z`).
  final String? shortcutHint;

  /// Optional status pill indicating current active/toggle state (`Active`, `On`).
  final String? activeBadge;

  /// Additional space-separated search terms and synonyms for fuzzy matching.
  final String keywords;

  /// Optional leading Material icon displayed beside the row.
  final IconData? icon;

  /// Grapheme-cluster character indices in [title] matched by the active query.
  final List<int> matchedTitleIndices;

  /// Optional section header grouping consecutive rows (e.g. `Recently Used`).
  final String? groupLabel;

  /// Action executed when the user commits this item (`Enter` or click).
  final FutureOr<void> Function()? onExecute;

  /// Optional live preview callback invoked when this item becomes highlighted.
  final VoidCallback? onPreview;

  /// Creates an immutable [PaletteItem].
  const PaletteItem({
    required this.id,
    this.category,
    required this.title,
    this.subtitle,
    this.shortcutHint,
    this.activeBadge,
    this.keywords = '',
    this.icon,
    this.matchedTitleIndices = const <int>[],
    this.groupLabel,
    this.onExecute,
    this.onPreview,
  });

  /// Returns a copy with updated match indices or section grouping.
  PaletteItem copyWith({
    List<int>? matchedTitleIndices,
    String? groupLabel,
    bool clearGroupLabel = false,
  }) => PaletteItem(
    id: id,
    category: category,
    title: title,
    subtitle: subtitle,
    shortcutHint: shortcutHint,
    activeBadge: activeBadge,
    keywords: keywords,
    icon: icon,
    matchedTitleIndices: matchedTitleIndices ?? this.matchedTitleIndices,
    groupLabel: clearGroupLabel ? null : (groupLabel ?? this.groupLabel),
    onExecute: onExecute,
    onPreview: onPreview,
  );
}
