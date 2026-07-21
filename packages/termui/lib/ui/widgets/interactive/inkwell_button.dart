import 'dart:async';
import 'dart:math';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

/// A button widget with hover elevation (floating shadow) and pressed radial gradient inkwell ripple animation.
class InkwellButton extends StatefulWidget implements MouseEventHandler {
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
    this.focusNode,
    this.autofocus = false,
    this.highlightBackground,
    this.highlightForeground,
    this.onFocusChange,
  });

  /// Called when the focus state of the button changes.
  final void Function(bool)? onFocusChange;

  /// The background color when the button is focused or hovered.
  /// If null, a lighter or darker shade of [color1] will be computed automatically.
  final Color? highlightBackground;

  /// The foreground color when the button is focused or hovered.
  /// If null, the default foreground color is used.
  final Color? highlightForeground;

  /// An optional external focus node.
  final FocusNode? focusNode;

  /// Automatically request focus on mount.
  final bool autofocus;

  // Keep a reference to the active state.
  InkwellButtonState? _state;

  /// Translates mouse interactions to update hover and pressed states.
  @override
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
    with
        TuiAnimatedStateMixin<InkwellButton>,
        FocusableStateMixin<InkwellButton>
    implements MouseEventHandler {
  late final InkwellRippleEffect _ripple;

  @override
  bool get isWidgetFocused => widget.autofocus;

  @override
  String get focusNodeIdPrefix => 'inkwell_btn';

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

  bool _isInternalFocusNode = true;

  @override
  void initState() {
    super.initState();

    _ripple = InkwellRippleEffect(
      duration: const Duration(milliseconds: 200),
      rippleColor: widget.color2,
    );

    registerEffect(_ripple);

    // Override the auto-created focus node if one was provided.
    if (widget.focusNode != null) {
      focusNode.dispose();
      focusNode = widget.focusNode!;
      _isInternalFocusNode = false;
    }
  }

  @override
  void didUpdateWidget(InkwellButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      if (_isInternalFocusNode) {
        focusNode.dispose();
      }
      if (widget.focusNode != null) {
        focusNode = widget.focusNode!;
        _isInternalFocusNode = false;
      } else {
        focusNode = FocusNode(id: '${focusNodeIdPrefix}_${widget.hashCode}');
        _isInternalFocusNode = true;
      }
    }
  }

  @override
  void dispose() {
    if (_isInternalFocusNode) {
      focusNode.dispose();
    }
    super.dispose();
  }

  /// Handles mouse interactions.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    final resolvedWidth = widget.width ?? _lastWidth;
    final resolvedHeight = widget.height ?? _lastHeight;
    if (resolvedWidth <= 0 || resolvedHeight <= 0) return;

    final fallback = resolvedWidth < 2 || resolvedHeight < 2;
    final bodyW = fallback ? resolvedWidth : resolvedWidth - 1;
    final bodyH = fallback ? resolvedHeight : resolvedHeight - 1;

    final inBounds =
        localX >= 0 && localX < bodyW && localY >= 0 && localY < bodyH;

    if (event.type == MouseEventType.press) {
      if (inBounds) {
        focusNode.requestFocus();
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
          reverseEffect(_ripple);
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

    final bool hasFocus = focusNode.hasFocus;
    final bool isHighlighted = hasFocus || _isHovered;

    Color resolvedHighlightBg =
        widget.highlightBackground ?? _computeHighlightColor(widget.color1);
    final Color effectiveBg = isHighlighted
        ? resolvedHighlightBg
        : widget.color1;
    final Color effectiveFg =
        isHighlighted && widget.highlightForeground != null
        ? widget.highlightForeground!
        : (widget.textStyle.foreground ?? Colors.white);
    final baseStyle = Style(background: effectiveBg);

    // Clear rendering area with transparent cells first
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        buffer.setAttributes(
          x,
          y,
          char: ' ',
          fg: 0,
          bg: 0,
          modifiers: Modifier.transparent,
        );
      }
    }

    if (W < 2 || H < 2) {
      // Fallback for extremely small sizes
      for (var y = 0; y < H; y++) {
        for (var x = 0; x < W; x++) {
          buffer.setAttributes(
            x,
            y,
            char: ' ',
            fg: 0,
            bg: effectiveBg.argb,
            modifiers: Modifier.none,
          );
        }
      }

      // Delegate overlay drawing to the animation mixin
      paintEffects(buffer, Rect(0, 0, W, H), baseStyle);

      if (widget.text.isNotEmpty) {
        final textLen = widget.text.characters.length;
        final startX = max(0, (W - textLen) ~/ 2);

        // Ensure text contrast against possibly animated background
        final bgArgb = buffer.getBackground(startX, max(0, (H - 1) ~/ 2));
        final bgColor = bgArgb != 0 ? Color.argb(bgArgb) : effectiveBg;

        buffer.writeString(
          startX,
          max(0, (H - 1) ~/ 2),
          widget.text,
          widget.textStyle.merge(
            Style(background: bgColor, foreground: effectiveFg),
          ),
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
        buffer.setAttributes(
          W - 1,
          y,
          char: '▐',
          fg: shadowStyle.foreground?.argb ?? 0,
          bg: shadowStyle.background?.argb ?? 0,
          modifiers: shadowStyle.modifiers,
        );
      }
      // Bottom row H - 1 (from column 1 to W - 1) draws Lower Half-Block '▄'
      for (var x = 1; x < W; x++) {
        buffer.setAttributes(
          x,
          H - 1,
          char: '▄',
          fg: shadowStyle.foreground?.argb ?? 0,
          bg: shadowStyle.background?.argb ?? 0,
          modifiers: shadowStyle.modifiers,
        );
      }
    }

    // Draw body
    final textChars = widget.text.characters.toList();
    final textLen = textChars.length;
    final textY = (bodyHeight - 1) ~/ 2;
    final textX = (bodyWidth - textLen) ~/ 2;

    // Paint baseline button cells (only spaces first)
    for (var by = 0; by < bodyHeight; by++) {
      for (var bx = 0; bx < bodyWidth; bx++) {
        buffer.setAttributes(
          bodyX + bx,
          bodyY + by,
          char: ' ',
          fg: baseStyle.foreground?.argb ?? 0,
          bg: baseStyle.background?.argb ?? 0,
          modifiers: baseStyle.modifiers,
        );
      }
    }

    // Delegate overlay drawing to the animation mixin
    paintEffects(buffer, Rect(bodyX, bodyY, bodyWidth, bodyHeight), baseStyle);

    // Precalculate foreground styling and luminance outside the loop
    Style baseResolvedTextStyle = widget.textStyle.merge(
      Style(foreground: effectiveFg),
    );
    double? baseFgLuminance;
    if (baseResolvedTextStyle.foreground != null) {
      final fgColor = baseResolvedTextStyle.foreground!;
      baseFgLuminance =
          0.299 * fgColor.r + 0.587 * fgColor.g + 0.114 * fgColor.b;
    }

    // Now draw the text on top, adjusting foreground for contrast
    for (var i = 0; i < textLen; i++) {
      final bx = textX + i;
      final by = textY;

      String char = textChars[i];
      if (bx >= 0 && bx < bodyWidth && by >= 0 && by < bodyHeight) {
        final bgArgb = buffer.getBackground(bodyX + bx, bodyY + by);
        final bgR = bgArgb != 0
            ? (bgArgb >> 16) & 0xFF
            : (baseStyle.background?.r ?? 0);
        final bgG = bgArgb != 0
            ? (bgArgb >> 8) & 0xFF
            : (baseStyle.background?.g ?? 0);
        final bgB = bgArgb != 0
            ? bgArgb & 0xFF
            : (baseStyle.background?.b ?? 0);

        Style resolvedTextStyle = baseResolvedTextStyle;
        if (baseFgLuminance != null) {
          final bgLuminance = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB;
          // Check if contrast is too low (e.g. both dark or both light)
          final bothDark = baseFgLuminance < 110 && bgLuminance < 110;
          final bothLight = baseFgLuminance >= 110 && bgLuminance >= 110;
          if (bothDark) {
            final fg =
                (widget.color1.r < 50 &&
                    widget.color1.g < 50 &&
                    widget.color1.b < 50)
                ? Colors.white
                : widget.color1;
            resolvedTextStyle = widget.textStyle.merge(Style(foreground: fg));
          } else if (bothLight) {
            resolvedTextStyle = widget.textStyle.merge(
              const Style(foreground: Colors.black),
            );
          }
        }

        final oldModifiers = buffer.getModifiers(bodyX + bx, bodyY + by);
        var mergedModifiers = oldModifiers | resolvedTextStyle.modifiers;
        if ((resolvedTextStyle.modifiers & Modifier.transparent) == 0) {
          mergedModifiers &= ~Modifier.transparent;
        }
        final oldFg = buffer.getForeground(bodyX + bx, bodyY + by);

        buffer.setAttributes(
          bodyX + bx,
          bodyY + by,
          char: char,
          fg: resolvedTextStyle.foreground?.argb ?? oldFg,
          bg: resolvedTextStyle.background?.argb ?? bgArgb,
          modifiers: mergedModifiers,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    widget._state = this;
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (event) {
        if (event.type == KeyType.character &&
            (event.key == ' ' || event.key == '\r' || event.key == '\n')) {
          triggerEffect(
            _ripple,
            Point((widget.width ?? 10) ~/ 2, (widget.height ?? 3) ~/ 2),
          );
          Timer.periodic(TuiAnimationConfig.vsyncInterval, (timer) {
            if (!mounted) {
              timer.cancel();
              return;
            }
            if (_ripple.status == AnimationStatus.completed) {
              reverseEffect(_ripple);
              widget.onPressed();
              timer.cancel();
            }
          });
          return true;
        }
        return false;
      },
      onFocusChange: (focused) {
        if (mounted) setState(() {});
        widget.onFocusChange?.call(focused);
      },
      child: _InkwellButtonRenderWidget(this),
    );
  }

  Color _computeHighlightColor(Color base) {
    final luminance = 0.299 * base.r + 0.587 * base.g + 0.114 * base.b;
    // If the base color is light, darken it. Otherwise, lighten it.
    if (luminance > 128) {
      return Color(
        max(0, base.r - 40),
        max(0, base.g - 40),
        max(0, base.b - 40),
      );
    } else {
      return Color(
        min(255, base.r + 40),
        min(255, base.g + 40),
        min(255, base.b + 40),
      );
    }
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
  void performPaint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final wWidget = widget as _InkwellButtonRenderWidget;
    final state = wWidget.state;
    state._render(viewport, Rect(0, 0, size.width, size.height));
  }
}
