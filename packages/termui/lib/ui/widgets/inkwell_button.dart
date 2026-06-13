import 'dart:math';
import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../color.dart';
import '../layout.dart';
import '../event.dart' hide Modifier;
import '../animation/effects.dart';
import '../animation/animated_state_mixin.dart';

/// A button widget with hover elevation (floating shadow) and pressed radial gradient inkwell ripple animation.
class InkwellButton extends StatefulWidget {
  /// The label text.
  final String text;

  /// The click handler.
  final void Function() onPressed;

  /// The first color for the radial gradient.
  final Color color1;

  /// The second color for the radial gradient.
  final Color color2;

  /// The style of the label text.
  final Style textStyle;

  /// Optional width constraint.
  final int? width;

  /// Optional height constraint.
  final int? height;

  /// Creates a new [InkwellButton].
  InkwellButton({
    required this.text,
    required this.onPressed,
    this.color1 = CharmColors.charple,
    this.color2 = CharmColors.hazy,
    this.textStyle = const Style(
      foreground: Colors.white,
      modifiers: Modifier.bold,
    ),
    this.width,
    this.height,
  });

  // Keep a reference to the active state.
  InkwellButtonState? _state;

  /// Translates mouse interactions to update hover and pressed states.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    _state?.handleMouseEvent(event, localX, localY);
  }

  @override
  State<InkwellButton> createState() {
    final state = InkwellButtonState();
    _state = state;
    return state;
  }
}

/// The state for an [InkwellButton].
class InkwellButtonState extends State<InkwellButton>
    with TuiAnimatedStateMixin<InkwellButton> {
  late final InkwellRippleEffect _ripple;

  bool _isHovered = false;
  bool _isPressed = false;
  int _lastWidth = 0;
  int _lastHeight = 0;

  /// Exposed for testing
  bool get isHovered => _isHovered;

  /// Exposed for testing
  bool get isPressed => _isPressed;

  /// Exposed for testing
  double get rippleProgress => _ripple.isVisible ? _ripple.progress : 0.0;

  /// Exposed for testing
  double get rippleCenterX => _ripple.triggerPoint?.x.toDouble() ?? 0.0;

  /// Exposed for testing
  double get rippleCenterY => _ripple.triggerPoint?.y.toDouble() ?? 0.0;

  @override
  void initState() {
    super.initState();

    _ripple = InkwellRippleEffect(
      duration: const Duration(milliseconds: 200),
      rippleColor: widget.color2,
    );

    registerEffect(_ripple);
  }

  /// Handles mouse interactions.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    final resolvedWidth = widget.width ?? _lastWidth;
    final resolvedHeight = widget.height ?? _lastHeight;
    if (resolvedWidth <= 0 || resolvedHeight <= 0) return;

    // Body is always at (0, 0) with width W - 1 and height H - 1
    final inBounds =
        localX >= 0 &&
        localX < resolvedWidth - 1 &&
        localY >= 0 &&
        localY < resolvedHeight - 1;

    if (event.type == MouseEventType.press) {
      if (inBounds) {
        setState(() {
          _isPressed = true;
          _isHovered = false;

          final clickPoint = Point(localX, localY);
          triggerEffect(_ripple, clickPoint);
        });
      }
    } else if (event.type == MouseEventType.release) {
      if (_isPressed) {
        setState(() {
          _isPressed = false;
          _ripple.reset();
          if (inBounds) {
            _isHovered = true;
            widget.onPressed();
          } else {
            _isHovered = false;
          }
        });
      }
    } else if (event.type == MouseEventType.move ||
        event.type == MouseEventType.drag) {
      final oldHovered = _isHovered;
      _isHovered = inBounds && !_isPressed;
      if (_isHovered != oldHovered) {
        setState(() {});
      }
    }
  }

  void _render(Buffer buffer, Rect area) {
    final W = widget.width ?? area.width;
    final H = widget.height ?? area.height;
    _lastWidth = W;
    _lastHeight = H;

    if (W <= 0 || H <= 0) return;

    // Clear rendering area with transparent cells first
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        buffer.setCell(x, y, Cell(' ', Style.transparent));
      }
    }

    if (W < 2 || H < 2) {
      // Fallback for extremely small sizes
      for (var y = 0; y < H; y++) {
        for (var x = 0; x < W; x++) {
          buffer.setCell(x, y, Cell(' ', Style(background: widget.color1)));
        }
      }
      if (widget.text.isNotEmpty) {
        final textLen = widget.text.characters.length;
        final startX = max(0, (W - textLen) ~/ 2);
        buffer.writeString(
          startX,
          max(0, (H - 1) ~/ 2),
          widget.text,
          widget.textStyle.merge(Style(background: widget.color1)),
        );
      }
      return;
    }

    // Body is always at (0, 0) in all states
    const int bodyX = 0;
    const int bodyY = 0;
    final int bodyWidth = W - 1;
    final int bodyHeight = H - 1;

    // Draw shadow if hovering (and not pressed)
    if (_isHovered && !_isPressed) {
      final shadowStyle = const Style(
        foreground: Color(64, 64, 64),
        modifiers: Modifier.dim,
      );
      // Rightmost column W - 1 (from row 1 to H - 2) draws Right Half-Block '▐'
      for (var y = 1; y < H - 1; y++) {
        buffer.setCell(W - 1, y, Cell('▐', shadowStyle));
      }
      // Bottom row H - 1 (from column 1 to W - 1) draws Lower Half-Block '▄'
      for (var x = 1; x < W; x++) {
        buffer.setCell(x, H - 1, Cell('▄', shadowStyle));
      }
    }

    // Draw body
    final textChars = widget.text.characters.toList();
    final textLen = textChars.length;
    final textY = (bodyHeight - 1) ~/ 2;
    final textX = (bodyWidth - textLen) ~/ 2;

    // Paint baseline button cells
    final baseStyle = Style(background: widget.color1);
    for (var by = 0; by < bodyHeight; by++) {
      for (var bx = 0; bx < bodyWidth; bx++) {
        if (by == textY && bx >= textX && bx < textX + textLen) {
          final charIndex = bx - textX;
          buffer.setCell(
            bodyX + bx,
            bodyY + by,
            Cell(textChars[charIndex], widget.textStyle.merge(baseStyle)),
          );
        } else {
          buffer.setCell(bodyX + bx, bodyY + by, Cell(' ', baseStyle));
        }
      }
    }

    // Delegate overlay drawing to the animation mixin
    paintEffects(buffer, Rect(bodyX, bodyY, bodyWidth, bodyHeight), baseStyle);
  }

  @override
  Widget build(BuildContext context) {
    widget._state = this;
    return _InkwellButtonRenderWidget(this);
  }
}

class _InkwellButtonRenderWidget extends Widget {
  final InkwellButtonState state;
  const _InkwellButtonRenderWidget(this.state);

  @override
  Element createElement() => _InkwellButtonElement(this);
}

class _InkwellButtonElement extends Element {
  _InkwellButtonElement(_InkwellButtonRenderWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as _InkwellButtonRenderWidget;
    final state = wWidget.state;
    final w =
        state.widget.width ??
        (constraints.maxWidth == BoxConstraints.infinity
            ? 0
            : constraints.maxWidth);
    final h =
        state.widget.height ??
        (constraints.maxHeight == BoxConstraints.infinity
            ? 0
            : constraints.maxHeight);
    state._lastWidth = w;
    state._lastHeight = h;
    return constraints.constrain(Size(w, h));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final wWidget = widget as _InkwellButtonRenderWidget;
    final state = wWidget.state;
    state._render(viewport, Rect(0, 0, size.width, size.height));
  }
}
