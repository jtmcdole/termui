import 'package:material_ui/material_ui.dart';

/// Semantic version of `fterm` that [whatsNewHighlights] was authored for.
///
/// `.github/workflows/release-fterm-prepare.yml` compares the `major.minor`
/// pair of this constant against the bumped `apps/fterm/pubspec.yaml` version
/// and adds a refresh reminder to the release PR whenever a minor or major
/// release advances ahead of these cards.
const String whatsNewContentVersion = '0.8.1';

/// Optional interactive footer rendered at the bottom of a [WhatsNewHighlight]
/// card inside the What's New modal.
enum WhatsNewCardAction {
  /// No interactive footer.
  none,

  /// Button that opens the VS Code-style Command Palette (`>` mode).
  openCommandPalette,

  /// Button that opens the Blender-style Settings modal.
  openSettings,

  /// Live GPU shader preset preview chips (`Wave + Glow`, `Retro Phosphor CRT`,
  /// and one-click `Revert`).
  shaderTryIt,
}

/// Curated feature highlight card shown inside the `fterm` What's New modal.
final class WhatsNewHighlight {
  /// Stable identifier for this card.
  final String id;

  /// Leading Material icon displayed next to [title].
  final IconData icon;

  /// Short card heading.
  final String title;

  /// Concise summary of the capability and its primary shortcut or behavior.
  final String description;

  /// Optional interactive footer action rendered below [description].
  final WhatsNewCardAction action;

  /// Creates an immutable [WhatsNewHighlight].
  const WhatsNewHighlight({
    required this.id,
    required this.icon,
    required this.title,
    required this.description,
    this.action = .none,
  });
}

/// Ordered highlight cards rendered in the What's New modal for
/// [whatsNewContentVersion].
const List<WhatsNewHighlight> whatsNewHighlights = <WhatsNewHighlight>[
  WhatsNewHighlight(
    id: 'command-palette',
    icon: Icons.terminal,
    title: 'VS Code-Style Command Palette',
    description:
        'Press Ctrl+Shift+P (Cmd+Shift+P on macOS) or Ctrl+\\ Shift+P to '
        'fuzzy-search commands with out-of-order tokens, drag inline setting '
        'sliders, jump to scrollback lines or prompts (:), search history (%), '
        'or switch tabs and panes.',
    action: .openCommandPalette,
  ),
  WhatsNewHighlight(
    id: 'blender-settings',
    icon: Icons.tune,
    title: 'Blender-Style Settings Overhaul & Live Search',
    description:
        'Navigate categorized sidebar panels with collapsible sections, '
        'cross-category live search with per-section match badges, and unified '
        'controls synced with the Command Palette.',
    action: .openSettings,
  ),
  WhatsNewHighlight(
    id: 'shader-editor-estop',
    icon: Icons.code,
    title: 'Built-In GLSL Shader Editor & Emergency Stop',
    description:
        'Edit custom Ghostty .glsl shaders in a split tab (Ctrl+\\ e) with '
        'live debounced compile, Save As (Alt+S / Cmd+S), GPU watchdog '
        'recovery, and instant Emergency Stop (Ctrl+Shift+F6 / Ctrl+\\ 0).',
  ),
  WhatsNewHighlight(
    id: 'keyboard-chords-meta',
    icon: Icons.keyboard_outlined,
    title: 'Ignored Chords Recorder & Meta/Cmd Policy',
    description:
        'Record shortcut chords to pass straight through to tmux, vim, or '
        'browser tools, choose Meta/Cmd pass-through vs. Kitty protocol '
        'behavior, and toggle F12 host shortcuts.',
  ),
  WhatsNewHighlight(
    id: 'ghostty-shaders',
    icon: Icons.auto_awesome,
    title: 'Ghostty GLSL Shaders & Built-In Presets',
    description:
        'Drop Ghostty .glsl shaders into your shaders folder or stack '
        'built-in GPU passes (flutter_gpu on desktop, WebGL2 on web) with live '
        'preview and one-click revert.',
    action: .shaderTryIt,
  ),
];
