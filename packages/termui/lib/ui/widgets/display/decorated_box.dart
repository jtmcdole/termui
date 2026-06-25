import 'package:termui/termui.dart';

/// Represents the character set and style configuration used to draw a box border.
///
/// It supports various configurations including:
/// - [Border.single]: Standard single-line Unicode box characters (`┌`, `┐`, `└`, `┘`, `─`, `│`).
/// - [Border.doubleLine]: Double-line Unicode box characters (`╔`, `╗`, `╚`, `╝`, `═`, `║`).
/// - [Border.rounded]: Unicode box characters with rounded corners (`╭`, `╮`, `╰`, `╯`, `─`, `│`).
/// - [Border.ascii]: Portability-first plain ASCII characters (`+`, `-`, `|`).
/// - [Border.none]: Blank border lines.
///
/// ### Example Usage
///
/// ```dart
/// const border = Border(
///   style: Style(foreground: Color(0xFF00FF00)), // Green borders
///   topChar: '─',
///   bottomChar: '─',
///   leftChar: '│',
///   rightChar: '│',
/// );
/// ```
///
/// ### Configuration Properties
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `style` | [Style] | Style attributes applied to the border cells. |
/// | `topChar` | [String] | Character used for the top horizontal border. |
/// | `bottomChar` | [String] | Character used for the bottom horizontal border. |
/// | `leftChar` | [String] | Character used for the left vertical border. |
/// | `rightChar` | [String] | Character used for the right vertical border. |
/// | `topLeftChar` | [String] | Character used for the top-left corner. |
/// | `topRightChar` | [String] | Character used for the top-right corner. |
/// | `bottomLeftChar` | [String] | Character used for the bottom-left corner. |
/// | `bottomRightChar` | [String] | Character used for the bottom-right corner. |
class Border {
  /// Style attributes applied to the border cells.
  final Style style;

  /// Character used for the top horizontal border.
  final String topChar;

  /// Character used for the bottom horizontal border.
  final String bottomChar;

  /// Character used for the left vertical border.
  final String leftChar;

  /// Character used for the right vertical border.
  final String rightChar;

  /// Character used for the top-left corner.
  final String topLeftChar;

  /// Character used for the top-right corner.
  final String topRightChar;

  /// Character used for the bottom-left corner.
  final String bottomLeftChar;

  /// Character used for the bottom-right corner.
  final String bottomRightChar;

  /// Creates a new [Border] configuration.
  const Border({
    this.style = Style.empty,
    this.topChar = '─',
    this.bottomChar = '─',
    this.leftChar = '│',
    this.rightChar = '│',
    this.topLeftChar = '┌',
    this.topRightChar = '┐',
    this.bottomLeftChar = '└',
    this.bottomRightChar = '┘',
  });

  /// Creates a single-line border with the specified [style] on all sides.
  const Border.all([Style style = Style.empty]) : this(style: style);

  /// No borders.
  static const Border none = Border(
    topChar: '',
    bottomChar: '',
    leftChar: '',
    rightChar: '',
    topLeftChar: '',
    topRightChar: '',
    bottomLeftChar: '',
    bottomRightChar: '',
  );

  /// Standard single-line border.
  static const Border single = Border();

  /// Double-line border.
  static const Border doubleLine = Border(
    topChar: '═',
    bottomChar: '═',
    leftChar: '║',
    rightChar: '║',
    topLeftChar: '╔',
    topRightChar: '╗',
    bottomLeftChar: '╚',
    bottomRightChar: '╝',
  );

  /// Muted rounded corners border.
  static const Border rounded = Border(
    topLeftChar: '╭',
    topRightChar: '╮',
    bottomLeftChar: '╰',
    bottomRightChar: '╯',
  );

  /// Pure ASCII border for high portability.
  static const Border ascii = Border(
    topChar: '-',
    bottomChar: '-',
    leftChar: '|',
    rightChar: '|',
    topLeftChar: '+',
    topRightChar: '+',
    bottomLeftChar: '+',
    bottomRightChar: '+',
  );
}

/// Defines the visual decoration style (background and borders) for a box.
///
/// Consists of an optional background style and an optional [Border].
///
/// ### Example Usage
///
/// ```dart
/// const decoration = BoxDecoration(
///   backgroundStyle: Style(background: Color(0xFF0000FF)),
///   border: Border.rounded,
/// );
/// ```
///
/// ### Properties
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `backgroundStyle`| [Style]? | The style (e.g. color) used to paint background cells. |
/// | `border` | [Border]? | The border style configuration. |
class BoxDecoration {
  /// The style used to paint the background.
  final Style? backgroundStyle;

  /// The background color.
  final Color? backgroundColor;

  /// The border configuration.
  final Border? border;

  /// Creates a new [BoxDecoration].
  const BoxDecoration({
    this.backgroundStyle,
    this.backgroundColor,
    this.border,
  });
}

/// A widget that paints a background decoration and border around a child widget.
///
/// Shrinks the child's rendering viewport by the width of the active borders
/// so the child does not overlap with the border lines.
///
/// ### Example Usage
///
/// ```dart
/// DecoratedBox(
///   decoration: BoxDecoration(
///     border: Border.doubleLine,
///   ),
///   child: Text('Content inside a double-bordered box'),
/// );
/// ```
///
/// ### Properties
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `decoration` | [BoxDecoration] | Visual border and background layout settings. |
/// | `child` | [Widget] | The nested child widget to render inside the box. |
class DecoratedBox extends Widget {
  /// Visual border and background layout settings.
  final BoxDecoration decoration;

  /// The nested child widget to render inside the box.
  final Widget child;

  /// Creates a [DecoratedBox] with the given [decoration] and [child].
  const DecoratedBox({required this.decoration, required this.child});

  @override
  Element createElement() => DecoratedBoxElement(this);
}

/// Element for [DecoratedBox].
class DecoratedBoxElement extends SingleChildElement {
  int _cachedTopOffset = 0;
  int _cachedBottomOffset = 0;
  int _cachedLeftOffset = 0;
  int _cachedRightOffset = 0;

  /// Creates a decoratedbox element for a [DecoratedBox] widget.
  DecoratedBoxElement(DecoratedBox super.widget);

  @override
  Widget? get childWidget => (widget as DecoratedBox).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    final db = widget as DecoratedBox;
    final border = db.decoration.border;

    _cachedTopOffset = 0;
    _cachedBottomOffset = 0;
    _cachedLeftOffset = 0;
    _cachedRightOffset = 0;

    if (border != null) {
      if (border.topChar.isNotEmpty) {
        _cachedTopOffset = 1;
      }
      if (border.bottomChar.isNotEmpty) {
        _cachedBottomOffset = 1;
      }
      if (border.leftChar.isNotEmpty) {
        _cachedLeftOffset = 1;
      }
      if (border.rightChar.isNotEmpty) {
        _cachedRightOffset = 1;
      }
    }

    final doubleWidth = _cachedLeftOffset + _cachedRightOffset;
    final doubleHeight = _cachedTopOffset + _cachedBottomOffset;

    final childConstraints = BoxConstraints(
      minWidth: constraints.minWidth - doubleWidth < 0
          ? 0
          : constraints.minWidth - doubleWidth,
      maxWidth: constraints.maxWidth == BoxConstraints.infinity
          ? BoxConstraints.infinity
          : (constraints.maxWidth - doubleWidth < 0
                ? 0
                : constraints.maxWidth - doubleWidth),
      minHeight: constraints.minHeight - doubleHeight < 0
          ? 0
          : constraints.minHeight - doubleHeight,
      maxHeight: constraints.maxHeight == BoxConstraints.infinity
          ? BoxConstraints.infinity
          : (constraints.maxHeight - doubleHeight < 0
                ? 0
                : constraints.maxHeight - doubleHeight),
    );

    if (childElement != null) {
      final childSize = childElement!.layout(childConstraints);
      childElement!.relativeOffset = Offset(
        _cachedLeftOffset,
        _cachedTopOffset,
      );
      return Size(
        childSize.width + doubleWidth,
        childSize.height + doubleHeight,
      );
    }

    return Size(doubleWidth, doubleHeight);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final db = widget as DecoratedBox;
    final area = Rect(offset.dx, offset.dy, size.width, size.height);

    // Fill background if defined
    var bgStyle = db.decoration.backgroundStyle;
    if (bgStyle == null && db.decoration.backgroundColor != null) {
      bgStyle = Style(background: db.decoration.backgroundColor);
    }
    if (bgStyle != null) {
      for (var y = 0; y < area.height; y++) {
        for (var x = 0; x < area.width; x++) {
          buffer.setAttributes(
            area.x + x,
            area.y + y,
            char: ' ',
            fg: bgStyle.foreground?.argb,
            bg: bgStyle.background?.argb,
            modifiers: bgStyle.modifiers,
          );
        }
      }
    }

    // Draw border if defined
    final border = db.decoration.border;

    if (border != null) {
      final style = bgStyle != null
          ? bgStyle.merge(border.style)
          : border.style;

      // Draw horizontal lines (excluding corners)
      if (border.topChar.isNotEmpty && area.height > 0) {
        for (var x = 1; x < area.width - 1; x++) {
          buffer.setAttributes(
            area.x + x,
            area.y,
            char: border.topChar,
            fg: style.foreground?.argb,
            bg: style.background?.argb,
            modifiers: style.modifiers,
          );
        }
      }
      if (border.bottomChar.isNotEmpty && area.height > 1) {
        for (var x = 1; x < area.width - 1; x++) {
          buffer.setAttributes(
            area.x + x,
            area.y + area.height - 1,
            char: border.bottomChar,
            fg: style.foreground?.argb,
            bg: style.background?.argb,
            modifiers: style.modifiers,
          );
        }
      }

      // Draw vertical lines (excluding corners)
      if (border.leftChar.isNotEmpty && area.width > 0) {
        for (var y = 1; y < area.height - 1; y++) {
          buffer.setAttributes(
            area.x,
            area.y + y,
            char: border.leftChar,
            fg: style.foreground?.argb,
            bg: style.background?.argb,
            modifiers: style.modifiers,
          );
        }
      }
      if (border.rightChar.isNotEmpty && area.width > 1) {
        for (var y = 1; y < area.height - 1; y++) {
          buffer.setAttributes(
            area.x + area.width - 1,
            area.y + y,
            char: border.rightChar,
            fg: style.foreground?.argb,
            bg: style.background?.argb,
            modifiers: style.modifiers,
          );
        }
      }

      // Draw corners
      if (border.topLeftChar.isNotEmpty && area.width > 0 && area.height > 0) {
        buffer.setAttributes(
          area.x,
          area.y,
          char: border.topLeftChar,
          fg: style.foreground?.argb,
          bg: style.background?.argb,
          modifiers: style.modifiers,
        );
      }
      if (border.topRightChar.isNotEmpty && area.width > 1 && area.height > 0) {
        buffer.setAttributes(
          area.x + area.width - 1,
          area.y,
          char: border.topRightChar,
          fg: style.foreground?.argb,
          bg: style.background?.argb,
          modifiers: style.modifiers,
        );
      }
      if (border.bottomLeftChar.isNotEmpty &&
          area.width > 0 &&
          area.height > 1) {
        buffer.setAttributes(
          area.x,
          area.y + area.height - 1,
          char: border.bottomLeftChar,
          fg: style.foreground?.argb,
          bg: style.background?.argb,
          modifiers: style.modifiers,
        );
      }
      if (border.bottomRightChar.isNotEmpty &&
          area.width > 1 &&
          area.height > 1) {
        buffer.setAttributes(
          area.x + area.width - 1,
          area.y + area.height - 1,
          char: border.bottomRightChar,
          fg: style.foreground?.argb,
          bg: style.background?.argb,
          modifiers: style.modifiers,
        );
      }
    }

    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}
