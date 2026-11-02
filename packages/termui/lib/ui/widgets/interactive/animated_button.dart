import 'dart:math';
import 'package:characters/characters.dart';

import 'package:termui/termui.dart';

/// A button widget featuring multiple layered custom animation effects.
class AnimatedButton extends StatefulWidget {
  /// The text label displayed on the button.
  final String text;

  /// Callback executed when the button is pressed and released.
  final void Function() onPressed;

  /// The baseline style (foreground/background) of the button.
  final Style style;

  /// The width constraint of the button. If null, stretches to fit.
  final int? width;

  /// The height constraint of the button. If null, stretches to fit.
  final int? height;

  /// Creates an [AnimatedButton] with custom properties.
  const AnimatedButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.style = const Style(
      background: CharmColors.charple,
      foreground: Colors.white,
    ),
    this.width,
    this.height,
  });

  @override
  State<AnimatedButton> createState() => AnimatedButtonState();
}

/// The mutable state for [AnimatedButton], mixing in the TUI animation ticker capability.
class AnimatedButtonState extends State<AnimatedButton>
    with TuiAnimatedStateMixin<AnimatedButton>
    implements MouseEventHandler {
  late final InkwellRippleEffect _ripple;
  late final SparkleEffect _sparkles;
  late final FlashEffect _flash;

  bool _isHovered = false;
  bool _isPressed = false;
  int _lastWidth = 0;
  int _lastHeight = 0;

  /// Whether the mouse cursor is currently hovering over the button bounds.
  bool get isHovered => _isHovered;

  /// Whether the button is currently in a pressed state.
  bool get isPressed => _isPressed;

  @override
  void initState() {
    super.initState();

    // Initialize animation effects
    _ripple = InkwellRippleEffect(
      duration: const Duration(milliseconds: 400),
      rippleColor: CharmColors.hazy,
    );

    _sparkles = SparkleEffect(
      duration: const Duration(milliseconds: 600),
      density: 3,
    );

    _flash = FlashEffect(
      duration: const Duration(milliseconds: 350),
      flashColor: Colors.white,
      pulses: 1,
    );

    // Register animations with the lifecycle manager mixin
    registerEffect(_ripple);
    registerEffect(_sparkles);
    registerEffect(_flash);
  }

  /// Handles mouse movement, press, and release within this button's bounds.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    final resolvedWidth = _lastWidth > 0 ? _lastWidth : (widget.width ?? 0);
    final resolvedHeight = _lastHeight > 0 ? _lastHeight : (widget.height ?? 0);
    if (resolvedWidth <= 0 || resolvedHeight <= 0) return;

    final inBounds =
        localX >= 0 &&
        localX < resolvedWidth &&
        localY >= 0 &&
        localY < resolvedHeight;

    switch (event.type) {
      case MouseEventType.press when inBounds:
        _handlePress(localX, localY);
      case MouseEventType.release when _isPressed:
        _handleRelease(localX, localY, inBounds);
      case MouseEventType.move || MouseEventType.drag:
        setState(() {
          _isHovered = inBounds && !_isPressed;
        });
      default:
        break;
    }
  }

  void _handlePress(int localX, int localY) {
    setState(() {
      _isPressed = true;
      _isHovered = false;

      final clickPoint = Point(localX, localY);
      // Trigger both the radial ripple and the sparkle trail on the click coordinates
      triggerEffect(_ripple, clickPoint);
      triggerEffect(_sparkles, clickPoint);
    });
  }

  void _handleRelease(int localX, int localY, bool inBounds) {
    setState(() {
      _isPressed = false;
      _ripple.reset();
      _sparkles.reset();
      if (inBounds) {
        _isHovered = true;

        // Trigger a full layout flash upon successful button activation
        triggerEffect(_flash, Point(localX, localY));
        widget.onPressed();
      }
    });
  }

  @override
  Widget build(BuildContext context) => _AnimatedButtonRenderWidget(this);
}

class _AnimatedButtonRenderWidget extends Widget {
  final AnimatedButtonState state;
  const _AnimatedButtonRenderWidget(this.state);

  @override
  Element createElement() => _AnimatedButtonElement(this);
}

class _AnimatedButtonElement extends Element {
  _AnimatedButtonElement(_AnimatedButtonRenderWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as _AnimatedButtonRenderWidget;
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
    final constrainedSize = constraints.constrain(Size(w, h));
    state._lastWidth = constrainedSize.width;
    state._lastHeight = constrainedSize.height;
    return constrainedSize;
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final wWidget = widget as _AnimatedButtonRenderWidget;
    final state = wWidget.state;
    final W = size.width;
    final H = size.height;
    state._lastWidth = W;
    state._lastHeight = H;

    // 1. Draw base widget background cell grid
    final baseStyle = state.widget.style;
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        viewport.setAttributes(
          x,
          y,
          char: ' ',
          fg: baseStyle.foreground?.argb ?? 0,
          bg: baseStyle.background?.argb ?? 0,
          modifiers: baseStyle.modifiers,
        );
      }
    }

    // 2. Draw button text label centered inside the viewport
    final textLen = state.widget.text.characters.length;
    final startX = max(0, (W - textLen) ~/ 2);
    final startY = max(0, (H - 1) ~/ 2);
    viewport.writeString(startX, startY, state.widget.text, baseStyle);

    // 3. Delegate overlays to the animation framework mixin.
    state.paintEffects(viewport, Rect(0, 0, W, H), baseStyle);
  }
}
