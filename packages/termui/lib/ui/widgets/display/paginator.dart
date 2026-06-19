import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

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
  Element createElement() => PaginatorElement(this);
}

/// An element that manages the rendering and layout of a [Paginator] widget.
class PaginatorElement extends Element {
  /// Creates a [PaginatorElement] for the given [widget].
  PaginatorElement(Paginator super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final paginator = widget as Paginator;
    if (paginator.totalPages <= 0) return constraints.constrain(Size.zero);

    final dotChars = paginator.activeDot.characters;
    final inactiveDotChars = paginator.inactiveDot.characters;
    final separatorChars = paginator.separator.characters;

    var w = 0;
    for (var i = 0; i < paginator.totalPages; i++) {
      final isCurrent = i == paginator.currentPage;
      w += isCurrent ? dotChars.length : inactiveDotChars.length;
      if (i < paginator.totalPages - 1) {
        w += separatorChars.length;
      }
    }
    return constraints.constrain(Size(w, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final paginator = widget as Paginator;
    if (paginator.totalPages <= 0 || size.width <= 0 || size.height <= 0) {
      return;
    }

    final current = paginator.currentPage.clamp(0, paginator.totalPages - 1);
    final dotChars = paginator.activeDot.characters;
    final inactiveDotChars = paginator.inactiveDot.characters;
    final separatorChars = paginator.separator.characters;

    var currentX = 0;
    for (var i = 0; i < paginator.totalPages; i++) {
      final isCurrent = i == current;
      final dot = isCurrent ? paginator.activeDot : paginator.inactiveDot;
      final dotLen = isCurrent ? dotChars.length : inactiveDotChars.length;
      final dotStyle = isCurrent
          ? paginator.activeStyle
          : paginator.inactiveStyle;

      if (currentX + dotLen > size.width) break;
      viewport.writeString(currentX, 0, dot, dotStyle);
      currentX += dotLen;

      if (i < paginator.totalPages - 1) {
        if (currentX + separatorChars.length > size.width) break;
        viewport.writeString(
          currentX,
          0,
          paginator.separator,
          paginator.separatorStyle,
        );
        currentX += separatorChars.length;
      }
    }
  }
}
