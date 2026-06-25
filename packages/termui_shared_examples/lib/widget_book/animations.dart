import 'dart:math';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Example showcasing the new TUI Animation Framework effects
/// (Inkwell Ripple, Sparkle Particles, and Background Flash).
class AnimationsExample extends WidgetBookExample {
  /// The click count of the inkwell ripple button.
  int inkwellClicks = 0;

  /// The click count of the sparkle particle button.
  int sparkleClicks = 0;

  /// The click count of the background flash button.
  int flashClicks = 0;

  late final ElementWidget _inkwellWrapper = ElementWidget(
    InkwellButton(
      text: 'Inkwell Ripple',
      onPressed: () {
        inkwellClicks++;
      },
      color1: CharmColors.charple,
      color2: CharmColors.hazy,
    ),
  );

  late final ElementWidget _sparkleWrapper = ElementWidget(
    SparkleButton(
      text: 'Sparkle Particles',
      onPressed: () {
        sparkleClicks++;
      },
    ),
  );

  late final ElementWidget _flashWrapper = ElementWidget(
    FlashButton(
      text: 'Background Flash',
      onPressed: () {
        flashClicks++;
      },
    ),
  );

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return Column([
      SizedBox(
        height: 1,
        child: Text(
          'TUI Animation Framework Effects',
          style: const Style(
            foreground: Colors.white,
            background: CharmColors.charple,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      SizedBox(height: 1),
      SizedBox(
        height: 1,
        child: Text('Hover to lift button, press to trigger the animation:'),
      ),
      SizedBox(height: 2),

      // 1. Inkwell Ripple
      SizedBox(
        height: 1,
        child: Text(
          '1. Inkwell Ripple (expanding radial background color):',
          style: const Style(
            foreground: CharmColors.squid,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      SizedBox(height: 1),
      SizedBox(
        height: 4,
        child: Row([
          SizedBox(width: 25, child: _inkwellWrapper),
          const SizedBox(width: 2),
          SizedBox(
            width: 20,
            child: Center(
              child: Text(
                'Clicks: $inkwellClicks',
                style: const Style(
                  foreground: CharmColors.julep,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
          ),
        ]),
      ),
      SizedBox(height: 2),

      // 2. Sparkle Particle
      SizedBox(
        height: 1,
        child: Text(
          '2. Sparkle Particles (glowing simulated particle trail):',
          style: const Style(
            foreground: CharmColors.squid,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      SizedBox(height: 1),
      SizedBox(
        height: 4,
        child: Row([
          SizedBox(width: 25, child: _sparkleWrapper),
          const SizedBox(width: 2),
          SizedBox(
            width: 20,
            child: Center(
              child: Text(
                'Clicks: $sparkleClicks',
                style: const Style(
                  foreground: CharmColors.julep,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
          ),
        ]),
      ),
      SizedBox(height: 2),

      // 3. Background Flash
      SizedBox(
        height: 1,
        child: Text(
          '3. Background Flash (sine-wave full-widget pulsation):',
          style: const Style(
            foreground: CharmColors.squid,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      SizedBox(height: 1),
      SizedBox(
        height: 4,
        child: Row([
          SizedBox(width: 25, child: _flashWrapper),
          const SizedBox(width: 2),
          SizedBox(
            width: 20,
            child: Center(
              child: Text(
                'Clicks: $flashClicks',
                style: const Style(
                  foreground: CharmColors.julep,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    // 1. Inkwell Button (row 7..10)
    final isInsideInkwell =
        localY >= 7 && localY < 11 && localX >= 0 && localX < 25;
    if (isInsideInkwell) {
      final button = _inkwellWrapper.child as InkwellButton;
      button.handleMouseEvent(event, localX, localY - 7);
    } else {
      final button = _inkwellWrapper.child as InkwellButton;
      button.handleMouseEvent(event, -1, -1);
    }

    // 2. Sparkle Button (row 15..18)
    final isInsideSparkle =
        localY >= 15 && localY < 19 && localX >= 0 && localX < 25;
    if (isInsideSparkle) {
      final button = _sparkleWrapper.child as SparkleButton;
      button.handleMouseEvent(event, localX, localY - 15);
    } else {
      final button = _sparkleWrapper.child as SparkleButton;
      button.handleMouseEvent(event, -1, -1);
    }

    // 3. Flash Button (row 23..26)
    final isInsideFlash =
        localY >= 23 && localY < 27 && localX >= 0 && localX < 25;
    if (isInsideFlash) {
      final button = _flashWrapper.child as FlashButton;
      button.handleMouseEvent(event, localX, localY - 23);
    } else {
      final button = _flashWrapper.child as FlashButton;
      button.handleMouseEvent(event, -1, -1);
    }
  }

  @override
  Map<String, String> get helpBindings => {
    'Mouse Click': 'Press button to trigger effect',
    'Mouse Hover': 'Hover button to lift',
  };
}

/// A button that showcases the sparkle animation effect.
class SparkleButton extends StatefulWidget {
  /// The button label text.
  final String text;

  /// Callback executed when the button is activated.
  final void Function() onPressed;

  /// Creates a [SparkleButton].
  SparkleButton({required this.text, required this.onPressed});

  // Keep a reference to the active state.
  SparkleButtonState? _state;

  /// Handles mouse interactions.
  void handleMouseEvent(ui.MouseEvent event, int localX, int localY) {
    _state?.handleMouseEvent(event, localX, localY);
  }

  @override
  State<SparkleButton> createState() {
    final state = SparkleButtonState();
    _state = state;
    return state;
  }
}

/// The state for [SparkleButton].
class SparkleButtonState extends State<SparkleButton>
    with TuiAnimatedStateMixin<SparkleButton> {
  late final SparkleEffect _sparkles;
  bool _isHovered = false;
  bool _isPressed = false;
  int _lastWidth = 0;
  int _lastHeight = 0;

  @override
  void initState() {
    super.initState();
    _sparkles = SparkleEffect(
      duration: const Duration(milliseconds: 600),
      density: 3,
    );
    registerEffect(_sparkles);
  }

  /// Handles mouse interactions.
  void handleMouseEvent(ui.MouseEvent event, int localX, int localY) {
    final resolvedWidth = _lastWidth;
    final resolvedHeight = _lastHeight;
    if (resolvedWidth <= 0 || resolvedHeight <= 0) return;

    final inBounds =
        localX >= 0 &&
        localX < resolvedWidth - 1 &&
        localY >= 0 &&
        localY < resolvedHeight - 1;

    if (event.type == ui.MouseEventType.press) {
      if (inBounds) {
        setState(() {
          _isPressed = true;
          _isHovered = false;
          triggerEffect(_sparkles, Point(localX, localY));
        });
      }
    } else if (event.type == ui.MouseEventType.release) {
      if (_isPressed) {
        setState(() {
          _isPressed = false;
          _sparkles.reset();
          if (inBounds) {
            _isHovered = true;
            widget.onPressed();
          } else {
            _isHovered = false;
          }
        });
      }
    } else if (event.type == ui.MouseEventType.move ||
        event.type == ui.MouseEventType.drag) {
      final oldHovered = _isHovered;
      _isHovered = inBounds && !_isPressed;
      if (_isHovered != oldHovered) {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SparkleButtonRenderWidget(this);
  }
}

class _SparkleButtonRenderWidget extends Widget {
  final SparkleButtonState state;
  const _SparkleButtonRenderWidget(this.state);

  @override
  Element createElement() => _SparkleButtonRenderElement(this);
}

class _SparkleButtonRenderElement extends Element {
  _SparkleButtonRenderElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final W = size.width;
    final H = size.height;
    final wWidget = widget as _SparkleButtonRenderWidget;
    wWidget.state._lastWidth = W;
    wWidget.state._lastHeight = H;

    if (W <= 0 || H <= 0) return;

    // Clear transparent
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + y,
          char: ' ',
          fg: Style.transparent.foreground?.argb,
          bg: Style.transparent.background?.argb,
          modifiers: Style.transparent.modifiers,
        );
      }
    }

    if (W < 2 || H < 2) return;

    final int bodyWidth = W - 1;
    final int bodyHeight = H - 1;

    // Draw shadow if hovering
    if (wWidget.state._isHovered && !wWidget.state._isPressed) {
      final shadowStyle = const Style(
        foreground: Color(64, 64, 64),
        modifiers: Modifier.dim,
      );
      for (var y = 1; y < H - 1; y++) {
        buffer.setAttributes(
          offset.dx + W - 1,
          offset.dy + y,
          char: '▐',
          fg: shadowStyle.foreground?.argb,
          bg: shadowStyle.background?.argb,
          modifiers: shadowStyle.modifiers,
        );
      }
      for (var x = 1; x < W; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + H - 1,
          char: '▄',
          fg: shadowStyle.foreground?.argb,
          bg: shadowStyle.background?.argb,
          modifiers: shadowStyle.modifiers,
        );
      }
    }

    final baseStyle = const Style(background: CharmColors.bok);
    // Draw body background
    for (var y = 0; y < bodyHeight; y++) {
      for (var x = 0; x < bodyWidth; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + y,
          char: ' ',
          fg: baseStyle.foreground?.argb,
          bg: baseStyle.background?.argb,
          modifiers: baseStyle.modifiers,
        );
      }
    }

    // Write text
    final textLen = wWidget.state.widget.text.characters.length;
    final startX = max(0, (bodyWidth - textLen) ~/ 2);
    final startY = max(0, (bodyHeight - 1) ~/ 2);
    buffer.writeString(
      offset.dx + startX,
      offset.dy + startY,
      wWidget.state.widget.text,
      const Style(
        foreground: Colors.white,
        modifiers: Modifier.bold,
      ).merge(baseStyle),
    );

    final v = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, bodyWidth, bodyHeight),
    );
    wWidget.state.paintEffects(v, Rect(0, 0, bodyWidth, bodyHeight), baseStyle);
  }
}

/// A button that showcases the background flash animation effect.
class FlashButton extends StatefulWidget {
  /// The button label text.
  final String text;

  /// Callback executed when the button is activated.
  final void Function() onPressed;

  /// Creates a [FlashButton].
  FlashButton({required this.text, required this.onPressed});

  // Keep a reference to the active state.
  FlashButtonState? _state;

  /// Handles mouse interactions.
  void handleMouseEvent(ui.MouseEvent event, int localX, int localY) {
    _state?.handleMouseEvent(event, localX, localY);
  }

  @override
  State<FlashButton> createState() {
    final state = FlashButtonState();
    _state = state;
    return state;
  }
}

/// The state for [FlashButton].
class FlashButtonState extends State<FlashButton>
    with TuiAnimatedStateMixin<FlashButton> {
  late final FlashEffect _flash;
  bool _isHovered = false;
  bool _isPressed = false;
  int _lastWidth = 0;
  int _lastHeight = 0;

  @override
  void initState() {
    super.initState();
    _flash = FlashEffect(
      duration: const Duration(milliseconds: 350),
      flashColor: Colors.yellow,
      pulses: 1,
    );
    registerEffect(_flash);
  }

  /// Handles mouse interactions.
  void handleMouseEvent(ui.MouseEvent event, int localX, int localY) {
    final resolvedWidth = _lastWidth;
    final resolvedHeight = _lastHeight;
    if (resolvedWidth <= 0 || resolvedHeight <= 0) return;

    final inBounds =
        localX >= 0 &&
        localX < resolvedWidth - 1 &&
        localY >= 0 &&
        localY < resolvedHeight - 1;

    if (event.type == ui.MouseEventType.press) {
      if (inBounds) {
        setState(() {
          _isPressed = true;
          _isHovered = false;
          triggerEffect(_flash, Point(localX, localY));
        });
      }
    } else if (event.type == ui.MouseEventType.release) {
      if (_isPressed) {
        setState(() {
          _isPressed = false;
          _flash.reset();
          if (inBounds) {
            _isHovered = true;
            widget.onPressed();
          } else {
            _isHovered = false;
          }
        });
      }
    } else if (event.type == ui.MouseEventType.move ||
        event.type == ui.MouseEventType.drag) {
      final oldHovered = _isHovered;
      _isHovered = inBounds && !_isPressed;
      if (_isHovered != oldHovered) {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _FlashButtonRenderWidget(this);
  }
}

class _FlashButtonRenderWidget extends Widget {
  final FlashButtonState state;
  const _FlashButtonRenderWidget(this.state);

  @override
  Element createElement() => _FlashButtonRenderElement(this);
}

class _FlashButtonRenderElement extends Element {
  _FlashButtonRenderElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final W = size.width;
    final H = size.height;
    final wWidget = widget as _FlashButtonRenderWidget;
    wWidget.state._lastWidth = W;
    wWidget.state._lastHeight = H;

    if (W <= 0 || H <= 0) return;

    // Clear transparent
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + y,
          char: ' ',
          fg: Style.transparent.foreground?.argb,
          bg: Style.transparent.background?.argb,
          modifiers: Style.transparent.modifiers,
        );
      }
    }

    if (W < 2 || H < 2) return;

    final int bodyWidth = W - 1;
    final int bodyHeight = H - 1;

    // Draw shadow if hovering
    if (wWidget.state._isHovered && !wWidget.state._isPressed) {
      final shadowStyle = const Style(
        foreground: Color(64, 64, 64),
        modifiers: Modifier.dim,
      );
      for (var y = 1; y < H - 1; y++) {
        buffer.setAttributes(
          offset.dx + W - 1,
          offset.dy + y,
          char: '▐',
          fg: shadowStyle.foreground?.argb,
          bg: shadowStyle.background?.argb,
          modifiers: shadowStyle.modifiers,
        );
      }
      for (var x = 1; x < W; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + H - 1,
          char: '▄',
          fg: shadowStyle.foreground?.argb,
          bg: shadowStyle.background?.argb,
          modifiers: shadowStyle.modifiers,
        );
      }
    }

    final baseStyle = const Style(background: CharmColors.ox);
    // Draw body background
    for (var y = 0; y < bodyHeight; y++) {
      for (var x = 0; x < bodyWidth; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + y,
          char: ' ',
          fg: baseStyle.foreground?.argb,
          bg: baseStyle.background?.argb,
          modifiers: baseStyle.modifiers,
        );
      }
    }

    // Write text
    final textLen = wWidget.state.widget.text.characters.length;
    final startX = max(0, (bodyWidth - textLen) ~/ 2);
    final startY = max(0, (bodyHeight - 1) ~/ 2);
    buffer.writeString(
      offset.dx + startX,
      offset.dy + startY,
      wWidget.state.widget.text,
      const Style(
        foreground: Colors.white,
        modifiers: Modifier.bold,
      ).merge(baseStyle),
    );

    final v = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, bodyWidth, bodyHeight),
    );
    wWidget.state.paintEffects(v, Rect(0, 0, bodyWidth, bodyHeight), baseStyle);
  }
}
