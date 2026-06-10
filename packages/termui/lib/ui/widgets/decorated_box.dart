import '../buffer.dart';
import '../color.dart';
import '../layout.dart';
import '../style.dart';

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

  @override
  void render(Buffer buffer, Rect area) {
    // Fill background if defined
    var bgStyle = decoration.backgroundStyle;
    if (bgStyle == null && decoration.backgroundColor != null) {
      bgStyle = Style(background: decoration.backgroundColor);
    }
    if (bgStyle != null) {
      for (var y = 0; y < area.height; y++) {
        for (var x = 0; x < area.width; x++) {
          buffer.setCell(area.x + x, area.y + y, Cell(' ', bgStyle));
        }
      }
    }

    // Draw border if defined
    final border = decoration.border;
    var topOffset = 0;
    var bottomOffset = 0;
    var leftOffset = 0;
    var rightOffset = 0;

    if (border != null) {
      final style = bgStyle != null
          ? bgStyle.merge(border.style)
          : border.style;

      // Draw horizontal lines (excluding corners)
      if (border.topChar.isNotEmpty && area.height > 0) {
        topOffset = 1;
        for (var x = 1; x < area.width - 1; x++) {
          buffer.setCell(area.x + x, area.y, Cell(border.topChar, style));
        }
      }
      if (border.bottomChar.isNotEmpty && area.height > 1) {
        bottomOffset = 1;
        for (var x = 1; x < area.width - 1; x++) {
          buffer.setCell(
            area.x + x,
            area.y + area.height - 1,
            Cell(border.bottomChar, style),
          );
        }
      }

      // Draw vertical lines (excluding corners)
      if (border.leftChar.isNotEmpty && area.width > 0) {
        leftOffset = 1;
        for (var y = 1; y < area.height - 1; y++) {
          buffer.setCell(area.x, area.y + y, Cell(border.leftChar, style));
        }
      }
      if (border.rightChar.isNotEmpty && area.width > 1) {
        rightOffset = 1;
        for (var y = 1; y < area.height - 1; y++) {
          buffer.setCell(
            area.x + area.width - 1,
            area.y + y,
            Cell(border.rightChar, style),
          );
        }
      }

      // Draw corners
      if (border.topLeftChar.isNotEmpty && area.width > 0 && area.height > 0) {
        buffer.setCell(area.x, area.y, Cell(border.topLeftChar, style));
      }
      if (border.topRightChar.isNotEmpty && area.width > 1 && area.height > 0) {
        buffer.setCell(
          area.x + area.width - 1,
          area.y,
          Cell(border.topRightChar, style),
        );
      }
      if (border.bottomLeftChar.isNotEmpty &&
          area.width > 0 &&
          area.height > 1) {
        buffer.setCell(
          area.x,
          area.y + area.height - 1,
          Cell(border.bottomLeftChar, style),
        );
      }
      if (border.bottomRightChar.isNotEmpty &&
          area.width > 1 &&
          area.height > 1) {
        buffer.setCell(
          area.x + area.width - 1,
          area.y + area.height - 1,
          Cell(border.bottomRightChar, style),
        );
      }
    }

    // Render child in remaining area
    final childX = area.x + leftOffset;
    final childY = area.y + topOffset;
    final childWidth = area.width - leftOffset - rightOffset;
    final childHeight = area.height - topOffset - bottomOffset;

    if (childWidth > 0 && childHeight > 0) {
      final childArea = Rect(childX, childY, childWidth, childHeight);
      final childViewport = Viewport(buffer, childArea);
      child.render(childViewport, Rect(0, 0, childWidth, childHeight));
    }
  }
}

/// Element for [DecoratedBox].
class DecoratedBoxElement extends Element {
  /// The element corresponding to the [DecoratedBox]'s child.
  Element? childElement;

  /// Creates a new [DecoratedBoxElement].
  DecoratedBoxElement(DecoratedBox super.widget);

  @override
  void render(Buffer buffer, Rect area) {
    final db = widget as DecoratedBox;

    // Fill background if defined
    var bgStyle = db.decoration.backgroundStyle;
    if (bgStyle == null && db.decoration.backgroundColor != null) {
      bgStyle = Style(background: db.decoration.backgroundColor);
    }
    if (bgStyle != null) {
      for (var y = 0; y < area.height; y++) {
        for (var x = 0; x < area.width; x++) {
          buffer.setCell(area.x + x, area.y + y, Cell(' ', bgStyle));
        }
      }
    }

    // Draw border if defined
    final border = db.decoration.border;
    var topOffset = 0;
    var bottomOffset = 0;
    var leftOffset = 0;
    var rightOffset = 0;

    if (border != null) {
      final style = bgStyle != null
          ? bgStyle.merge(border.style)
          : border.style;

      // Draw horizontal lines (excluding corners)
      if (border.topChar.isNotEmpty && area.height > 0) {
        topOffset = 1;
        for (var x = 1; x < area.width - 1; x++) {
          buffer.setCell(area.x + x, area.y, Cell(border.topChar, style));
        }
      }
      if (border.bottomChar.isNotEmpty && area.height > 1) {
        bottomOffset = 1;
        for (var x = 1; x < area.width - 1; x++) {
          buffer.setCell(
            area.x + x,
            area.y + area.height - 1,
            Cell(border.bottomChar, style),
          );
        }
      }

      // Draw vertical lines (excluding corners)
      if (border.leftChar.isNotEmpty && area.width > 0) {
        leftOffset = 1;
        for (var y = 1; y < area.height - 1; y++) {
          buffer.setCell(area.x, area.y + y, Cell(border.leftChar, style));
        }
      }
      if (border.rightChar.isNotEmpty && area.width > 1) {
        rightOffset = 1;
        for (var y = 1; y < area.height - 1; y++) {
          buffer.setCell(
            area.x + area.width - 1,
            area.y + y,
            Cell(border.rightChar, style),
          );
        }
      }

      // Draw corners
      if (border.topLeftChar.isNotEmpty && area.width > 0 && area.height > 0) {
        buffer.setCell(area.x, area.y, Cell(border.topLeftChar, style));
      }
      if (border.topRightChar.isNotEmpty && area.width > 1 && area.height > 0) {
        buffer.setCell(
          area.x + area.width - 1,
          area.y,
          Cell(border.topRightChar, style),
        );
      }
      if (border.bottomLeftChar.isNotEmpty &&
          area.width > 0 &&
          area.height > 1) {
        buffer.setCell(
          area.x,
          area.y + area.height - 1,
          Cell(border.bottomLeftChar, style),
        );
      }
      if (border.bottomRightChar.isNotEmpty &&
          area.width > 1 &&
          area.height > 1) {
        buffer.setCell(
          area.x + area.width - 1,
          area.y + area.height - 1,
          Cell(border.bottomRightChar, style),
        );
      }
    }

    final childX = area.x + leftOffset;
    final childY = area.y + topOffset;
    final childWidth = area.width - leftOffset - rightOffset;
    final childHeight = area.height - topOffset - bottomOffset;

    if (childWidth > 0 && childHeight > 0) {
      if (childElement != null &&
          childElement!.widget.runtimeType == db.child.runtimeType) {
        childElement!.update(db.child);
      } else {
        childElement = db.child.createElement();
        childElement!.mount(this);
      }

      final childArea = Rect(childX, childY, childWidth, childHeight);
      final childViewport = Viewport(buffer, childArea);
      childElement!.render(childViewport, Rect(0, 0, childWidth, childHeight));
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}
