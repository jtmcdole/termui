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
  bool _bordersDirty = true;

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
  void update(Widget newWidget) {
    super.update(newWidget);
    _bordersDirty = true;
  }

  void _computeBorderOffsets() {
    if (!_bordersDirty) return;
    _bordersDirty = false;
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

      _cachedLeftOffset = max(
        measureStringWidth(border.leftChar),
        max(_topLeftCharWidth, _bottomLeftCharWidth),
      );

      _cachedRightOffset = max(
        measureStringWidth(border.rightChar),
        max(_topRightCharWidth, _bottomRightCharWidth),
      );
    }
  }

  @override
  int getIntrinsicHeight(int width) {
    _computeBorderOffsets();
    final doubleWidth = _cachedLeftOffset + _cachedRightOffset;
    final doubleHeight = _cachedTopOffset + _cachedBottomOffset;
    final childWidth = max(0, width - doubleWidth);
    return (childElement?.getIntrinsicHeight(childWidth) ?? 0) + doubleHeight;
  }

  @override
  int getIntrinsicWidth(int height) {
    _computeBorderOffsets();
    final doubleWidth = _cachedLeftOffset + _cachedRightOffset;
    final doubleHeight = _cachedTopOffset + _cachedBottomOffset;
    final childHeight = max(0, height - doubleHeight);
    return (childElement?.getIntrinsicWidth(childHeight) ?? 0) + doubleWidth;
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    _computeBorderOffsets();

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
    var bgStyle = db.decoration.backgroundStyle;
    if (db.decoration.backgroundColor case final bgColor?) {
      final fallbackBg = Style(background: bgColor);
      bgStyle = bgStyle != null ? fallbackBg.merge(bgStyle) : fallbackBg;
    }

    if (bgStyle != null) {
      _paintBackground(buffer, area, bgStyle);
    }

    final border = db.decoration.border;
    if (border != null) {
      _paintBorder(buffer, area, db.decoration, border, bgStyle);
    }

    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  static void _paintBackground(Buffer buffer, Rect area, Style bgStyle) {
    final startY = max(0, -area.y);
    final endY = min(area.height, buffer.height - area.y);
    final startX = max(0, -area.x);
    final endX = min(area.width, buffer.width - area.x);
    if (startX >= endX || startY >= endY) return;

    final bgFg = bgStyle.foreground?.argb;
    final bgBg = bgStyle.background?.argb;
    final bgModifiers = bgStyle.modifiers;

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

  void _paintBorder(
    Buffer buffer,
    Rect area,
    BoxDecoration decoration,
    Border border,
    Style? bgStyle,
  ) {
    final baseStyle = bgStyle != null
        ? bgStyle.merge(border.style)
        : border.style;
    final gradient = _BorderGradient.fromDecoration(
      decoration,
      size,
      baseStyle,
    );
    Style cellStyle(int x, int y) =>
        gradient?.styleAt(x, y, baseStyle) ?? baseStyle;

    _paintHorizontalBorders(buffer, area, border, cellStyle);
    _paintVerticalBorders(buffer, area, border, cellStyle);
    _paintBorderCorners(buffer, area, border, cellStyle);
  }

  void _paintHorizontalBorders(
    Buffer buffer,
    Rect area,
    Border border,
    Style Function(int x, int y) cellStyle,
  ) {
    if (border.topChar.isNotEmpty && area.height > 0) {
      final step = max(1, _topCharWidth);
      for (
        var x = _cachedLeftOffset;
        x < area.width - _cachedRightOffset;
        x += step
      ) {
        buffer.writeString(area.x + x, area.y, border.topChar, cellStyle(x, 0));
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
          cellStyle(x, area.height - 1),
        );
      }
    }
  }

  void _paintVerticalBorders(
    Buffer buffer,
    Rect area,
    Border border,
    Style Function(int x, int y) cellStyle,
  ) {
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
          cellStyle(0, y),
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
          cellStyle(area.width - _cachedRightOffset, y),
        );
      }
    }
  }

  void _paintBorderCorners(
    Buffer buffer,
    Rect area,
    Border border,
    Style Function(int x, int y) cellStyle,
  ) {
    final hasRightRoom = area.width > _cachedLeftOffset + _cachedRightOffset;
    final hasBottomRoom = area.height > _cachedTopOffset + _cachedBottomOffset;

    if (border.topLeftChar.isNotEmpty && area.width > 0 && area.height > 0) {
      buffer.writeString(area.x, area.y, border.topLeftChar, cellStyle(0, 0));
    }
    if (border.topRightChar.isNotEmpty && hasRightRoom && area.height > 0) {
      buffer.writeString(
        area.x + area.width - _topRightCharWidth,
        area.y,
        border.topRightChar,
        cellStyle(area.width - _topRightCharWidth, 0),
      );
    }
    if (border.bottomLeftChar.isNotEmpty && area.width > 0 && hasBottomRoom) {
      buffer.writeString(
        area.x,
        area.y + area.height - 1,
        border.bottomLeftChar,
        cellStyle(0, area.height - 1),
      );
    }
    if (border.bottomRightChar.isNotEmpty && hasRightRoom && hasBottomRoom) {
      buffer.writeString(
        area.x + area.width - _bottomRightCharWidth,
        area.y + area.height - 1,
        border.bottomRightChar,
        cellStyle(area.width - _bottomRightCharWidth, area.height - 1),
      );
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

sealed class _BorderGradient {
  const _BorderGradient();

  static _BorderGradient? fromDecoration(
    BoxDecoration decoration,
    Size size,
    Style baseStyle,
  ) {
    final start = decoration.borderStartColor;
    final end = decoration.borderEndColor;
    if (start == null || end == null) return null;

    final angle = decoration.borderGradientAngle;
    final diffR = end.r - start.r;
    final diffG = end.g - start.g;
    final diffB = end.b - start.b;

    if (angle == 0.0) {
      final cache = List<Style>.generate(size.width, (x) {
        final ratio = size.width <= 1 ? 0.0 : x / (size.width - 1);
        final color = size.width <= 1
            ? start
            : _interpolateRgb(start, diffR, diffG, diffB, ratio);
        return Style(
          foreground: color,
          background: baseStyle.background,
          modifiers: baseStyle.modifiers,
        );
      });
      return _HorizontalBorderGradient(cache);
    }

    final cosA = cos(angle);
    final sinA = sin(angle);
    final dx = size.width - 1.0;
    final dy = size.height - 1.0;
    final pW0 = dx * cosA;
    final p0H = dy * sinA;
    final pWH = pW0 + p0H;
    final pMin = min(min(0.0, pW0), min(p0H, pWH));
    final pMax = max(max(0.0, pW0), max(p0H, pWH));

    return _AngledBorderGradient(
      startColor: start,
      diffR: diffR,
      diffG: diffG,
      diffB: diffB,
      cosA: cosA,
      sinA: sinA,
      pMin: pMin,
      pRange: pMax - pMin,
    );
  }

  Style styleAt(int x, int y, Style baseStyle);

  static Color _interpolateRgb(
    Color start,
    int diffR,
    int diffG,
    int diffB,
    double ratio,
  ) {
    final r = (start.r + diffR * ratio).round().clamp(0, 255);
    final g = (start.g + diffG * ratio).round().clamp(0, 255);
    final b = (start.b + diffB * ratio).round().clamp(0, 255);
    return Color(r, g, b);
  }
}

final class _HorizontalBorderGradient extends _BorderGradient {
  final List<Style> _cache;

  const _HorizontalBorderGradient(this._cache);

  @override
  Style styleAt(int x, int y, Style baseStyle) => _cache[x];
}

final class _AngledBorderGradient extends _BorderGradient {
  final Color startColor;
  final int diffR;
  final int diffG;
  final int diffB;
  final double cosA;
  final double sinA;
  final double pMin;
  final double pRange;

  const _AngledBorderGradient({
    required this.startColor,
    required this.diffR,
    required this.diffG,
    required this.diffB,
    required this.cosA,
    required this.sinA,
    required this.pMin,
    required this.pRange,
  });

  @override
  Style styleAt(int x, int y, Style baseStyle) {
    final color = pRange.abs() < 1e-5
        ? startColor
        : _BorderGradient._interpolateRgb(
            startColor,
            diffR,
            diffG,
            diffB,
            (x * cosA + y * sinA - pMin) / pRange,
          );
    return Style(
      foreground: color,
      background: baseStyle.background,
      modifiers: baseStyle.modifiers,
    );
  }
}
