import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:termui/terminal/event.dart' as ev;

import 'fterm_capability_context.dart';

/// Structured desktop keystroke matcher evaluated against an exact logical key
/// and modifier set.
final class FtermKeyStroke {
  /// Target logical key.
  final LogicalKeyboardKey key;

  /// Whether `Ctrl` must be held.
  final bool ctrl;

  /// Whether `Shift` must be held.
  final bool shift;

  /// Whether `Alt` / `Option` must be held.
  final bool alt;

  /// Whether `Meta` / `Cmd` must be held.
  final bool meta;

  /// Creates an exact-modifier keystroke matcher.
  const FtermKeyStroke(
    this.key, {
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  /// Returns `true` when [actual] equals [key] and [modifiers] matches the
  /// exact required modifier flags (`ctrl`, `shift`, `alt`, `meta`).
  bool matches(LogicalKeyboardKey actual, Set<ev.Modifier> modifiers) =>
      actual == key &&
      modifiers.contains(ev.Modifier.control) == ctrl &&
      modifiers.contains(ev.Modifier.shift) == shift &&
      modifiers.contains(ev.Modifier.alt) == alt &&
      modifiers.contains(ev.Modifier.meta) == meta;
}

/// Structured `Ctrl+\` leader-chord matcher supporting primary keys,
/// CapsLock-safe shift rules, alternate keys, shifted layout keys, and
/// layout-independent character fallbacks.
final class FtermLeaderChord {
  /// Primary logical key for this leader chord.
  final LogicalKeyboardKey key;

  /// Whether `Shift` must be active for [key] or [alternateKeys] to match.
  final bool requireShift;

  /// Whether `Shift` must be inactive for [key] or [alternateKeys] to match.
  final bool forbidShift;

  /// Additional logical keys matching under the same shift rules as [key]
  /// (for example `numpad0` alongside `digit0` or `space` alongside `keyD`).
  final List<LogicalKeyboardKey> alternateKeys;

  /// Logical keys that match only when `Shift` is held (for example `Shift+/`
  /// for `?`, or `Shift+\` for `|`).
  final List<LogicalKeyboardKey> shiftedKeys;

  /// Optional character literals accepted across non-US keyboard layouts (for
  /// example `?`, `,`, `|`, `%`, `-`, `"`).
  final List<String> characters;

  /// Creates a `Ctrl+\` leader-chord matcher.
  const FtermLeaderChord(
    this.key, {
    this.requireShift = false,
    this.forbidShift = false,
    this.alternateKeys = const <LogicalKeyboardKey>[],
    this.shiftedKeys = const <LogicalKeyboardKey>[],
    this.characters = const <String>[],
  }) : assert(
         !(requireShift && forbidShift),
         'requireShift and forbidShift cannot both be true',
       );

  /// Returns `true` when [actual] (and optional [character]) matches this
  /// leader chord under [shift].
  bool matches(
    LogicalKeyboardKey actual, {
    required bool shift,
    String? character,
  }) {
    if (character != null && characters.contains(character)) return true;
    if (shift && shiftedKeys.contains(actual)) return true;
    if (requireShift && !shift) return false;
    if (forbidShift && shift) return false;
    return actual == key || alternateKeys.contains(actual);
  }
}

/// Platform-aware shortcut display labels and structured keystroke/chord
/// matchers shared across Shortcut Dispatcher, Help Overlay, and Command
/// Palette.
final class FtermShortcutBinding {
  /// Palette/Help shortcut label displayed on macOS (for example `Cmd+D`).
  final String? macDesktopLabel;

  /// Palette/Help shortcut label displayed on Linux and Windows (for example
  /// `Ctrl+Shift+D`).
  final String? linuxWinDesktopLabel;

  /// Modal `Ctrl+\` leader-chord display label (for example `Ctrl+\ z`).
  final String? leaderChordLabel;

  /// Structured keystroke matched on native macOS desktop builds.
  final FtermKeyStroke? macDesktopStroke;

  /// Structured keystroke matched on native Linux and Windows desktop builds.
  final FtermKeyStroke? linuxWinDesktopStroke;

  /// Structured keystroke matched across all native desktop builds regardless
  /// of OS (for example `Ctrl+Shift+F5`, `Ctrl+Shift+F9`, `Ctrl+Shift+F10`).
  final FtermKeyStroke? universalDesktopStroke;

  /// Structured `Ctrl+\` leader-chord matcher shared across desktop and Web.
  final FtermLeaderChord? leaderChord;

  /// Whether [macDesktopLabel] and [linuxWinDesktopLabel] only apply on native
  /// desktop builds and must be suppressed on Web (falling back to
  /// [leaderChordLabel] or `null`).
  final bool desktopOnlyHint;

  /// Creates an immutable [FtermShortcutBinding].
  const FtermShortcutBinding({
    this.macDesktopLabel,
    this.linuxWinDesktopLabel,
    this.leaderChordLabel,
    this.macDesktopStroke,
    this.linuxWinDesktopStroke,
    this.universalDesktopStroke,
    this.leaderChord,
    this.desktopOnlyHint = false,
  });

  /// Formats the primary Command Palette shortcut pill for [ctx].
  ///
  /// When [desktopOnlyHint] is `true` on Web, desktop labels are suppressed so
  /// only [leaderChordLabel] (or `null`) is surfaced.
  String? formatPaletteHint(FtermCapabilityContext ctx) {
    if (ctx.isWeb && desktopOnlyHint) {
      return leaderChordLabel;
    }
    final desktopLabel = ctx.isMacOs ? macDesktopLabel : linuxWinDesktopLabel;
    return desktopLabel ?? leaderChordLabel;
  }

  /// Returns `true` when `(key, modifiers)` matches a native desktop keystroke
  /// bound for [ctx]. Always returns `false` on Web.
  bool matchesDesktopStroke(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
    FtermCapabilityContext ctx,
  ) {
    if (ctx.isWeb) return false;
    if (universalDesktopStroke case final stroke?
        when stroke.matches(key, modifiers)) {
      return true;
    }
    if (ctx.isMacOs) {
      return macDesktopStroke?.matches(key, modifiers) ?? false;
    }
    if (ctx.isLinux || ctx.isWindows) {
      return linuxWinDesktopStroke?.matches(key, modifiers) ?? false;
    }
    return false;
  }
}

/// Single row rendered in the Keyboard Shortcuts help overlay.
typedef HelpShortcutEntry = ({String keys, String description});
