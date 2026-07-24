import 'dart:math';
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
final class Border {
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

  /// Heavy-line border.
  static const Border heavy = Border(
    topChar: '━',
    bottomChar: '━',
    leftChar: '┃',
    rightChar: '┃',
    topLeftChar: '┏',
    topRightChar: '┓',
    bottomLeftChar: '┗',
    bottomRightChar: '┛',
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

  /// Light dashed border.
  static const Border dashed = Border(
    topChar: '╌',
    bottomChar: '╌',
    leftChar: '╎',
    rightChar: '╎',
    topLeftChar: '┌',
    topRightChar: '┐',
    bottomLeftChar: '└',
    bottomRightChar: '┘',
  );

  /// Solid retro block border.
  static const Border block = Border(
    topChar: '█',
    bottomChar: '█',
    leftChar: '█',
    rightChar: '█',
    topLeftChar: '█',
    topRightChar: '█',
    bottomLeftChar: '█',
    bottomRightChar: '█',
  );

  /// Light shaded block border.
  static const Border shadedLight = Border(
    topChar: '░',
    bottomChar: '░',
    leftChar: '░',
    rightChar: '░',
    topLeftChar: '░',
    topRightChar: '░',
    bottomLeftChar: '░',
    bottomRightChar: '░',
  );

  /// Medium shaded block border.
  static const Border shadedMedium = Border(
    topChar: '▒',
    bottomChar: '▒',
    leftChar: '▒',
    rightChar: '▒',
    topLeftChar: '▒',
    topRightChar: '▒',
    bottomLeftChar: '▒',
    bottomRightChar: '▒',
  );

  /// Dark shaded block border.
  static const Border shadedDark = Border(
    topChar: '▓',
    bottomChar: '▓',
    leftChar: '▓',
    rightChar: '▓',
    topLeftChar: '▓',
    topRightChar: '▓',
    bottomLeftChar: '▓',
    bottomRightChar: '▓',
  );

  /// Space-saving half-block border.
  static const Border halfBlock = Border(
    topChar: '▀',
    bottomChar: '▄',
    leftChar: '▌',
    rightChar: '▐',
    topLeftChar: '▛',
    topRightChar: '▜',
    bottomLeftChar: '▙',
    bottomRightChar: '▟',
  );

  /// Diagonal slash border (top-right to bottom-left).
  static const Border diagonalSlash = Border(
    topChar: '▞',
    bottomChar: '▞',
    leftChar: '▞',
    rightChar: '▞',
    topLeftChar: '▞',
    topRightChar: '▞',
    bottomLeftChar: '▞',
    bottomRightChar: '▞',
  );

  /// Diagonal backslash border (top-left to bottom-right).
  static const Border diagonalBackslash = Border(
    topChar: '▚',
    bottomChar: '▚',
    leftChar: '▚',
    rightChar: '▚',
    topLeftChar: '▚',
    topRightChar: '▚',
    bottomLeftChar: '▚',
    bottomRightChar: '▚',
  );

  /// Border using quadrant diagonals for the corners.
  static const Border quadDiagonals = Border(
    topChar: '▀',
    bottomChar: '▄',
    leftChar: '▌',
    rightChar: '▐',
    topLeftChar: '▞',
    topRightChar: '▚',
    bottomLeftChar: '▚',
    bottomRightChar: '▞',
  );

  /// Border using single quadrants for corners, creating an inner padding look.
  static const Border quadPadding = Border(
    topChar: '▀',
    bottomChar: '▄',
    leftChar: '▌',
    rightChar: '▐',
    topLeftChar: '▘',
    topRightChar: '▝',
    bottomLeftChar: '▖',
    bottomRightChar: '▗',
  );

  /// Border using Braille patterns for a high-density, dot-matrix outline.
  static const Border braille = Border(
    topChar: '⠉',
    bottomChar: '⣀',
    leftChar: '⡇',
    rightChar: '⢸',
    topLeftChar: '⡏',
    topRightChar: '⢹',
    bottomLeftChar: '⣇',
    bottomRightChar: '⣸',
  );
}

/// Defines the visual decoration style (background and borders) for a box.
///
/// Consists of an optional background style, background color, and an optional [Border].
/// It also supports linear color gradients on the borders using [borderStartColor],
/// [borderEndColor], and [borderGradientAngle].
///
/// ### Example Usage
///
/// ```dart
/// const decoration = BoxDecoration(
///   backgroundStyle: Style(background: Color(0xFF0000FF)),
///   border: Border.rounded,
///   borderStartColor: Color(0, 240, 200), // Teal start
///   borderEndColor: Color(180, 40, 250),  // Purple end
///   borderGradientAngle: 0.785,            // ~45 degrees diagonal gradient
/// );
/// ```
///
/// ### Properties
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `backgroundStyle`| [Style]? | The style (e.g. color) used to paint background cells. |
/// | `backgroundColor`| [Color]? | The background color. |
/// | `border` | [Border]? | The border style configuration. |
/// | `borderStartColor`| [Color]? | The starting color of the border gradient. |
/// | `borderEndColor`| [Color]? | The ending color of the border gradient. |
/// | `borderGradientAngle`| [double] | The angle of the border gradient in radians (defaults to 0.0). |
final class BoxDecoration {
  /// The style used to paint the background.
  final Style? backgroundStyle;

  /// The background color.
  final Color? backgroundColor;

  /// The border configuration.
  final Border? border;

  /// Starting color for horizontal border gradients.
  final Color? borderStartColor;

  /// Ending color for horizontal border gradients.
  final Color? borderEndColor;

  /// The angle of the border gradient in radians (defaults to 0.0, horizontal).
  final double borderGradientAngle;

  /// Creates a new [BoxDecoration].
  const BoxDecoration({
    this.backgroundStyle,
    this.backgroundColor,
    this.border,
    this.borderStartColor,
    this.borderEndColor,
    this.borderGradientAngle = 0.0,
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

  // Cached char widths to prevent measuring during paint
  int _topCharWidth = 0;
  int _bottomCharWidth = 0;
  int _topLeftCharWidth = 0;
  int _topRightCharWidth = 0;
  int _bottomLeftCharWidth = 0;
  int _bottomRightCharWidth = 0;

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
    _topCharWidth = 0;
    _bottomCharWidth = 0;
    _topLeftCharWidth = 0;
    _topRightCharWidth = 0;
    _bottomLeftCharWidth = 0;
    _bottomRightCharWidth = 0;

    if (border != null) {
      _topCharWidth = measureStringWidth(border.topChar);
      _bottomCharWidth = measureStringWidth(border.bottomChar);
      _topLeftCharWidth = measureStringWidth(border.topLeftChar);
      _topRightCharWidth = measureStringWidth(border.topRightChar);
      _bottomLeftCharWidth = measureStringWidth(border.bottomLeftChar);
      _bottomRightCharWidth = measureStringWidth(border.bottomRightChar);

      if (_topCharWidth > 0 ||
          _topLeftCharWidth > 0 ||
          _topRightCharWidth > 0) {
        _cachedTopOffset = 1;
      }
      if (_bottomCharWidth > 0 ||
          _bottomLeftCharWidth > 0 ||
          _bottomRightCharWidth > 0) {
        _cachedBottomOffset = 1;
      }

      _cachedLeftOffset = [
        measureStringWidth(border.leftChar),
        _topLeftCharWidth,
        _bottomLeftCharWidth,
      ].reduce(max);

      _cachedRightOffset = [
        measureStringWidth(border.rightChar),
        _topRightCharWidth,
        _bottomRightCharWidth,
      ].reduce(max);
    }

    final doubleWidth = _cachedLeftOffset + _cachedRightOffset;
    final doubleHeight = _cachedTopOffset + _cachedBottomOffset;

    final childConstraints = BoxConstraints(
      minWidth: max(0, constraints.minWidth - doubleWidth),
      maxWidth: constraints.maxWidth == BoxConstraints.infinity
          ? BoxConstraints.infinity
          : max(0, constraints.maxWidth - doubleWidth),
      minHeight: max(0, constraints.minHeight - doubleHeight),
      maxHeight: constraints.maxHeight == BoxConstraints.infinity
          ? BoxConstraints.infinity
          : max(0, constraints.maxHeight - doubleHeight),
    );

    if (childElement != null) {
      final childSize = childElement!.layout(childConstraints);
      childElement!.relativeOffset = Offset(
        _cachedLeftOffset,
        _cachedTopOffset,
      );
      return constraints.constrain(
        Size(childSize.width + doubleWidth, childSize.height + doubleHeight),
      );
    }

    return constraints.constrain(Size(doubleWidth, doubleHeight));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final db = widget as DecoratedBox;
    final area = Rect(offset.dx, offset.dy, size.width, size.height);

    // Merge backgroundStyle and backgroundColor correctly
    var bgStyle = db.decoration.backgroundStyle;
    if (db.decoration.backgroundColor != null) {
      final fallbackBg = Style(background: db.decoration.backgroundColor);
      bgStyle = bgStyle != null ? fallbackBg.merge(bgStyle) : fallbackBg;
    }

    if (bgStyle != null) {
      final bgFg = bgStyle.foreground?.argb;
      final bgBg = bgStyle.background?.argb;
      final bgModifiers = bgStyle.modifiers;

      final startY = max(0, -area.y);
      final endY = min(area.height, buffer.height - area.y);
      final startX = max(0, -area.x);
      final endX = min(area.width, buffer.width - area.x);

      if (startX < endX && startY < endY) {
        for (var y = startY; y < endY; y++) {
          final drawY = area.y + y;
          for (var x = startX; x < endX; x++) {
            buffer.setAttributes(
              area.x + x,
              drawY,
              char: ' ',
              fg: bgFg,
              bg: bgBg,
              modifiers: bgModifiers,
            );
          }
        }
      }
    }

    final border = db.decoration.border;
    if (border != null) {
      final style = bgStyle != null
          ? bgStyle.merge(border.style)
          : border.style;

      // Extract colors for gradient check
      final borderStart = db.decoration.borderStartColor;
      final borderEnd = db.decoration.borderEndColor;
      final hasGradient = borderStart != null && borderEnd != null;
      final angle = db.decoration.borderGradientAngle;

      double cosA = 0.0;
      double sinA = 0.0;
      double pMin = 0.0;
      double pRange = 0.0;
      int startR = 0, startG = 0, startB = 0;
      int diffR = 0, diffG = 0, diffB = 0;

      if (hasGradient) {
        final start = borderStart;
        final end = borderEnd;
        startR = start.r;
        startG = start.g;
        startB = start.b;
        diffR = end.r - startR;
        diffG = end.g - startG;
        diffB = end.b - startB;
      }

      if (hasGradient && angle != 0.0) {
        cosA = cos(angle);
        sinA = sin(angle);
        final dx = size.width - 1.0;
        final dy = size.height - 1.0;
        final p00 = 0.0;
        final pW0 = dx * cosA;
        final p0H = dy * sinA;
        final pWH = dx * cosA + dy * sinA;

        pMin = p00;
        if (pW0 < pMin) pMin = pW0;
        if (p0H < pMin) pMin = p0H;
        if (pWH < pMin) pMin = pWH;

        var pMax = p00;
        if (pW0 > pMax) pMax = pW0;
        if (p0H > pMax) pMax = p0H;
        if (pWH > pMax) pMax = pWH;

        pRange = pMax - pMin;
      }

      Color? getGradientColor(int x, int y) {
        if (!hasGradient) return null;
        final w = size.width;

        if (angle == 0.0) {
          if (w <= 1) return borderStart;
          final ratio = x / (w - 1);
          final r = (startR + diffR * ratio).round().clamp(0, 255);
          final g = (startG + diffG * ratio).round().clamp(0, 255);
          final b = (startB + diffB * ratio).round().clamp(0, 255);
          return Color(r, g, b);
        }

        if (pRange.abs() < 1e-5) return borderStart;
        final proj = x * cosA + y * sinA;
        final ratio = (proj - pMin) / pRange;
        final r = (startR + diffR * ratio).round().clamp(0, 255);
        final g = (startG + diffG * ratio).round().clamp(0, 255);
        final b = (startB + diffB * ratio).round().clamp(0, 255);
        return Color(r, g, b);
      }

      // Optimisation: Cache style objects for horizontal gradients (angle == 0.0)
      List<Style>? horizontalStyleCache;
      if (hasGradient && angle == 0.0) {
        horizontalStyleCache = List.generate(size.width, (x) {
          final gColor = getGradientColor(x, 0);
          return Style(
            foreground: gColor,
            background: style.background,
            modifiers: style.modifiers,
          );
        });
      }

      Style getCellStyle(int x, int y) {
        if (!hasGradient) return style;
        if (angle == 0.0 && horizontalStyleCache != null) {
          return horizontalStyleCache[x];
        }
        final gColor = getGradientColor(x, y);
        if (gColor != null) {
          return Style(
            foreground: gColor,
            background: style.background,
            modifiers: style.modifiers,
          );
        }
        return style;
      }

      // Draw horizontal lines (excluding corners)
      if (border.topChar.isNotEmpty && area.height > 0) {
        final step = max(1, _topCharWidth);
        for (
          var x = _cachedLeftOffset;
          x < area.width - _cachedRightOffset;
          x += step
        ) {
          buffer.writeString(
            area.x + x,
            area.y,
            border.topChar,
            getCellStyle(x, 0),
          );
        }
      }
      if (border.bottomChar.isNotEmpty && area.height > 1) {
        final step = max(1, _bottomCharWidth);
        for (
          var x = _cachedLeftOffset;
          x < area.width - _cachedRightOffset;
          x += step
        ) {
          buffer.writeString(
            area.x + x,
            area.y + area.height - 1,
            border.bottomChar,
            getCellStyle(x, area.height - 1),
          );
        }
      }

      // Draw vertical lines (excluding corners)
      if (border.leftChar.isNotEmpty && area.width > 0) {
        for (
          var y = _cachedTopOffset;
          y < area.height - _cachedBottomOffset;
          y++
        ) {
          buffer.writeString(
            area.x,
            area.y + y,
            border.leftChar,
            getCellStyle(0, y),
          );
        }
      }
      if (border.rightChar.isNotEmpty &&
          area.width > _cachedLeftOffset + _cachedRightOffset) {
        for (
          var y = _cachedTopOffset;
          y < area.height - _cachedBottomOffset;
          y++
        ) {
          buffer.writeString(
            area.x + area.width - _cachedRightOffset,
            area.y + y,
            border.rightChar,
            getCellStyle(area.width - _cachedRightOffset, y),
          );
        }
      }

      // Draw corners
      if (border.topLeftChar.isNotEmpty && area.width > 0 && area.height > 0) {
        buffer.writeString(
          area.x,
          area.y,
          border.topLeftChar,
          getCellStyle(0, 0),
        );
      }
      if (border.topRightChar.isNotEmpty &&
          area.width > _cachedLeftOffset + _cachedRightOffset &&
          area.height > 0) {
        buffer.writeString(
          area.x + area.width - _topRightCharWidth,
          area.y,
          border.topRightChar,
          getCellStyle(area.width - _topRightCharWidth, 0),
        );
      }
      if (border.bottomLeftChar.isNotEmpty &&
          area.width > 0 &&
          area.height > _cachedTopOffset + _cachedBottomOffset) {
        buffer.writeString(
          area.x,
          area.y + area.height - 1,
          border.bottomLeftChar,
          getCellStyle(0, area.height - 1),
        );
      }
      if (border.bottomRightChar.isNotEmpty &&
          area.width > _cachedLeftOffset + _cachedRightOffset &&
          area.height > _cachedTopOffset + _cachedBottomOffset) {
        buffer.writeString(
          area.x + area.width - _bottomRightCharWidth,
          area.y + area.height - 1,
          border.bottomRightChar,
          getCellStyle(area.width - _bottomRightCharWidth, area.height - 1),
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
