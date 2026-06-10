import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';

/// A pagination dots indicator widget (e.g. `○ ○ ● ○ ○`).
///
/// It renders a row of dot indicators representing pages, highlighting the
/// currently active page dot with [activeStyle] and [activeDot], and others
/// with [inactiveStyle] and [inactiveDot].
///
/// ### Example Usage
///
/// ```dart
/// Paginator(
///   totalPages: 5,
///   currentPage: 2,
///   activeDot: '★',
///   inactiveDot: '☆',
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `totalPages` | [int] | The total number of pages to display dots for. |
/// | `currentPage` | [int] | The zero-indexed current active page. |
/// | `activeStyle` | [Style] | Style applied to the active dot. |
/// | `inactiveStyle` | [Style] | Style applied to inactive dots (defaults to dim). |
/// | `separatorStyle`| [Style] | Style applied to separators (defaults to dim). |
/// | `activeDot` | [String] | Grapheme representing the active page dot. Defaults to `●`. |
/// | `inactiveDot` | [String] | Grapheme representing inactive page dots. Defaults to `•`. |
/// | `separator` | [String] | Spacer separator text between dots. Defaults to ` `. |
class Paginator extends Widget {
  /// The total number of pages to display dots for.
  final int totalPages;

  /// The zero-indexed current active page.
  final int currentPage;

  /// Style applied to the active dot.
  final Style activeStyle;

  /// Style applied to inactive dots (defaults to dim).
  final Style inactiveStyle;

  /// Style applied to separators (defaults to dim).
  final Style separatorStyle;

  /// Grapheme representing the active page dot. Defaults to `●`.
  final String activeDot;

  /// Grapheme representing inactive page dots. Defaults to `•`.
  final String inactiveDot;

  /// Spacer separator text between dots. Defaults to ` `.
  final String separator;

  /// Creates a [Paginator] widget.
  const Paginator({
    required this.totalPages,
    required this.currentPage,
    this.activeStyle = Style.empty,
    this.inactiveStyle = const Style(modifiers: Modifier.dim),
    this.separatorStyle = const Style(modifiers: Modifier.dim),
    this.activeDot = '●',
    this.inactiveDot = '•',
    this.separator = ' ',
  });

  @override
  void render(Buffer buffer, Rect area) {
    if (totalPages <= 0 || area.width <= 0 || area.height <= 0) return;

    final current = currentPage.clamp(0, totalPages - 1);

    final dotChars = activeDot.characters;
    final inactiveDotChars = inactiveDot.characters;
    final separatorChars = separator.characters;

    var currentX = 0;
    for (var i = 0; i < totalPages; i++) {
      final isCurrent = i == current;
      final dot = isCurrent ? activeDot : inactiveDot;
      final dotLen = isCurrent ? dotChars.length : inactiveDotChars.length;
      final dotStyle = isCurrent ? activeStyle : inactiveStyle;

      if (currentX + dotLen > area.width) break;
      buffer.writeString(currentX, 0, dot, dotStyle);
      currentX += dotLen;

      if (i < totalPages - 1) {
        if (currentX + separatorChars.length > area.width) break;
        buffer.writeString(currentX, 0, separator, separatorStyle);
        currentX += separatorChars.length;
      }
    }
  }
}
