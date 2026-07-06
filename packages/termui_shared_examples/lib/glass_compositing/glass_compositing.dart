// ignore_for_file: file_names
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:math';

import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';

// --- Shared State ---
import 'package:shared_preferences/shared_preferences.dart';

class FireConfig {
  final SharedPreferences prefs;

  FireConfig(this.prefs) {
    _themeIndex = prefs.getInt('themeIndex') ?? 0;
    _fontIndex = prefs.getInt('fontIndex') ?? 0;
    _autoAnimate = prefs.getBool('autoAnimate') ?? true;
  }

  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  double _flameHeight = 0.5;
  double get flameHeight => _flameHeight;
  set flameHeight(double value) {
    if (_flameHeight == value) return;
    _flameHeight = value;
    _notifyListeners();
  }

  double _speed = 1.0;
  double get speed => _speed;
  set speed(double value) {
    if (_speed == value) return;
    _speed = value;
    _notifyListeners();
  }

  double _wind = 0.0;
  double get wind => _wind;
  set wind(double value) {
    if (_wind == value) return;
    _wind = value;
    _notifyListeners();
  }

  int _themeIndex = 0;
  int get themeIndex => _themeIndex;
  set themeIndex(int value) {
    if (_themeIndex == value) return;
    _themeIndex = value;
    prefs.setInt('themeIndex', value);
    _notifyListeners();
  }

  int _fontIndex = 0;
  int get fontIndex => _fontIndex;
  set fontIndex(int value) {
    if (_fontIndex == value) return;
    _fontIndex = value;
    prefs.setInt('fontIndex', value);
    _notifyListeners();
  }

  bool _autoAnimate = true;
  bool get autoAnimate => _autoAnimate;
  set autoAnimate(bool value) {
    if (_autoAnimate == value) return;
    _autoAnimate = value;
    prefs.setBool('autoAnimate', value);
    _notifyListeners();
  }
}

// --- Fire Background Engine ---
class FireEngine {
  int width;
  int height;
  List<double> heatGrid;
  final Random _random = Random();

  FireEngine(this.width, this.height)
    : heatGrid = List.filled(width * height, 0.0);

  void resize(int newWidth, int newHeight) {
    if (newWidth == width && newHeight == height) return;
    final newGrid = List.filled(newWidth * newHeight, 0.0);
    final minW = min(width, newWidth);
    final minH = min(height, newHeight);

    for (var y = 0; y < minH; y++) {
      for (var x = 0; x < minW; x++) {
        newGrid[y * newWidth + x] = heatGrid[y * width + x];
      }
    }
    width = newWidth;
    height = newHeight;
    heatGrid = newGrid;
  }

  void tick(FireConfig config) {
    if (width == 0 || height == 0) return;

    for (var x = 0; x < width; x++) {
      final v = _random.nextDouble();
      final threshold = 1.0 - config.flameHeight * 0.8;
      heatGrid[(height - 1) * width + x] = v > threshold
          ? 1.0
          : (v * config.flameHeight);
    }

    for (var y = 0; y < height - 1; y++) {
      for (var x = 0; x < width; x++) {
        final srcY = y + 1;
        var sum = 0.0;
        var count = 0;

        sum += heatGrid[srcY * width + x];
        count++;

        if (x > 0) {
          sum += heatGrid[srcY * width + (x - 1)];
          count++;
        }
        if (x < width - 1) {
          sum += heatGrid[srcY * width + (x + 1)];
          count++;
        }

        var avg = sum / count;

        // Dynamic cooling based on flame height.
        // Higher flameHeight = less cooling = taller flames.
        final cooling = 0.25 - (config.flameHeight * 0.20);
        avg -= _random.nextDouble() * cooling;
        if (avg < 0) avg = 0;

        final rawWind =
            (_random.nextDouble() * 2.0 - 1.0) + (config.wind * 2.0);
        var dstX = x + rawWind.round();
        if (dstX < 0) dstX = 0;
        if (dstX >= width) dstX = width - 1;

        heatGrid[y * width + dstX] = avg;
      }
    }
  }
}

class FireRender extends Widget {
  final FireEngine engine;
  final FireConfig config;
  const FireRender(this.engine, this.config, {super.key});
  @override
  Element createElement() => FireRenderElement(this);
}

class FireRenderElement extends Element {
  FireRenderElement(FireRender super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(
      Size(constraints.maxWidth, constraints.maxHeight),
    );
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as FireRender;
    final engine = w.engine;
    final areaWidth = size.width.toInt();
    final areaHeight = size.height.toInt();

    engine.resize(areaWidth, areaHeight);

    const chars = [' ', '⠄', '⠂', '⠃', '⠪', '░', '▒', '▓', '█'];

    Color heatColor(double h, int theme) {
      if (theme == 0) {
        // Classic
        if (h > 0.8) return const Color(255, 255, 200);
        if (h > 0.6) return const Color(255, 200, 0);
        if (h > 0.4) return const Color(255, 100, 0);
        if (h > 0.2) return const Color(200, 0, 0);
        if (h > 0.05) return const Color(50, 0, 50);
        return Colors.black;
      } else if (theme == 1) {
        // Toxic
        if (h > 0.8) return const Color(200, 255, 200);
        if (h > 0.6) return const Color(0, 255, 0);
        if (h > 0.4) return const Color(0, 200, 0);
        if (h > 0.2) return const Color(0, 100, 50);
        if (h > 0.05) return const Color(0, 50, 0);
        return Colors.black;
      } else if (theme == 2) {
        // Ice
        if (h > 0.8) return const Color(200, 255, 255);
        if (h > 0.6) return const Color(0, 200, 255);
        if (h > 0.4) return const Color(0, 100, 255);
        if (h > 0.2) return const Color(0, 0, 200);
        if (h > 0.05) return const Color(0, 0, 50);
        return Colors.black;
      } else if (theme == 3) {
        // Arcane
        if (h > 0.8) return const Color(255, 200, 255);
        if (h > 0.6) return const Color(200, 50, 255);
        if (h > 0.4) return const Color(150, 0, 200);
        if (h > 0.2) return const Color(100, 0, 150);
        if (h > 0.05) return const Color(50, 0, 100);
        return Colors.black;
      } else if (theme == 4) {
        // Neon
        if (h > 0.8) return const Color(255, 255, 255);
        if (h > 0.6) return const Color(255, 0, 255);
        if (h > 0.4) return const Color(0, 255, 255);
        if (h > 0.2) return const Color(0, 150, 255);
        if (h > 0.05) return const Color(0, 50, 100);
        return Colors.black;
      } else {
        // Ghost
        if (h > 0.8) return const Color(255, 255, 255);
        if (h > 0.6) return const Color(200, 255, 220);
        if (h > 0.4) return const Color(150, 200, 180);
        if (h > 0.2) return const Color(100, 150, 120);
        if (h > 0.05) return const Color(50, 80, 70);
        return Colors.black;
      }
    }

    for (var y = 0; y < areaHeight; y++) {
      for (var x = 0; x < areaWidth; x++) {
        final heat = engine.heatGrid[y * areaWidth + x];
        var charIdx = (heat * (chars.length - 1)).round();
        if (charIdx < 0) charIdx = 0;
        if (charIdx >= chars.length) charIdx = chars.length - 1;

        final color = heatColor(heat, w.config.themeIndex);

        buffer.setAttributes(
          offset.dx.toInt() + x,
          offset.dy.toInt() + y,
          char: chars[charIdx],
          fg: color.argb,
          bg: Colors.black.argb,
          modifiers: 0,
        );
      }
    }
  }
}

class FireApp extends StatefulWidget {
  final FireConfig config;
  const FireApp({super.key, required this.config});
  @override
  State<FireApp> createState() => _FireAppState();
}

class _FireAppState extends State<FireApp> {
  late final FireEngine engine;
  Timer? _timer;
  double _accumulator = 0.0;

  late final Stopwatch _stopwatch;
  double _lastTime = 0.0;

  @override
  void initState() {
    super.initState();
    engine = FireEngine(80, 24);
    _stopwatch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      final now = _stopwatch.elapsedMilliseconds / 1000.0;
      final dt = now - _lastTime;
      _lastTime = now;

      // Base rate: 30 ticks per second * speed
      _accumulator += widget.config.speed * 30.0 * dt;
      bool ticked = false;
      while (_accumulator >= 1.0) {
        engine.tick(widget.config);
        _accumulator -= 1.0;
        ticked = true;
      }
      if (ticked) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FireRender(engine, widget.config);
  }
}

// --- Foreground 3D Text Widget ---

class MetallicTextRender extends Widget {
  final FireConfig config;
  const MetallicTextRender({super.key, required this.config});
  @override
  Element createElement() => MetallicTextRenderElement(this);
}

class MetallicTextRenderElement extends Element {
  MetallicTextRenderElement(MetallicTextRender super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as MetallicTextRender;
    final lines = _getTextLines(wWidget.config.fontIndex);
    final h = lines.length;
    var w = 0;
    for (final line in lines) {
      if (line.length > w) w = line.length;
    }
    return constraints.constrain(Size(w, h));
  }

  List<String> _getTextLines(int fontIndex) {
    switch (fontIndex) {
      case 1:
        return [
          r" ______   ______     ______     __    __     __  __     __   ",
          r"/\__  _\ /\  ___\   /\  == \   /\ '-./  \   /\ \/\ \   /\ \  ",
          r"\/_/\ \/ \ \  __\   \ \  __<   \ \ \-./\ \  \ \ \_\ \  \ \ \ ",
          r"   \ \_\  \ \_____\  \ \_\ \_\  \ \_\ \ \_\  \ \_____\  \ \_\",
          r"    \/_/   \/_____/   \/_/ /_/   \/_/  \/_/   \/_____/   \/_/",
        ];
      case 2:
        return [
          "████████╗███████╗██████╗ ███╗   ███╗██╗   ██╗██╗",
          "╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║   ██║██║",
          "   ██║   █████╗  ██████╔╝██╔████╔██║██║   ██║██║",
          "   ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║   ██║██║",
          "   ██║   ███████╗██║  ██║██║ ╚═╝ ██║╚██████╔╝██║",
          "   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝",
        ];
      case 3:
        return [
          "▄▄▄█████▓▓█████  ██▀███   ███▄ ▄███▓ █    ██  ██▓",
          "▓  ██▒ ▓▒▓█   ▀ ▓██ ▒ ██▒▓██▒▀█▀ ██▒ ██  ▓██▒▓██▒",
          "▒ ▓██░ ▒░▒███   ▓██ ░▄█ ▒▓██    ▓██░▓██  ▒██░▒██▒",
          "░ ▓██▓ ░ ▒▓█  ▄ ▒██▀▀█▄  ▒██    ▒██ ▓▓█  ░██░░██░",
          "  ▒██▒ ░ ░▒████▒░██▓ ▒██▒▒██▒   ░██▒▒▒█████▓ ░██░",
          "  ▒ ░░   ░░ ▒░ ░░ ▒▓ ░▒▓░░ ▒░   ░  ░░▒▓▒ ▒ ▒ ░▓  ",
          "    ░     ░ ░  ░  ░▒ ░ ▒░░  ░      ░░░▒░ ░ ░  ▒ ░",
          "  ░         ░     ░░   ░ ░      ░    ░░░ ░ ░  ▒ ░",
          "            ░  ░   ░            ░      ░      ░  ",
        ];
      case 4:
        return [
          " ███████████ ██████████ ███████████   ██████   ██████ █████  █████ █████",
          "░█░░░███░░░█░░███░░░░░█░░███░░░░░███ ░░██████ ██████ ░░███  ░░███ ░░███ ",
          "░   ░███  ░  ░███  █ ░  ░███    ░███  ░███░█████░███  ░███   ░███  ░███ ",
          "    ░███     ░██████    ░██████████   ░███░░███ ░███  ░███   ░███  ░███ ",
          "    ░███     ░███░░█    ░███░░░░░███  ░███ ░░░  ░███  ░███   ░███  ░███ ",
          "    ░███     ░███ ░   █ ░███    ░███  ░███      ░███  ░███   ░███  ░███ ",
          "    █████    ██████████ █████   █████ █████     █████ ░░████████   █████",
          "   ░░░░░    ░░░░░░░░░░ ░░░░░   ░░░░░ ░░░░░     ░░░░░   ░░░░░░░░   ░░░░░",
        ];
      case 0:
      default:
        return [
          r"_______ _______  ______ _______ _     _  _ ",
          r"   |    |______ |_____/ |  |  | |     |  | ",
          r"   |    |______ |    \_ |  |  | |_____|  | ",
        ];
    }
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final wWidget = widget as MetallicTextRender;
    final lines = _getTextLines(wWidget.config.fontIndex);
    const fgColor = CharmColors.zest; // Neon greenish yellow

    // Explicitly zero background for transparent compositor blending
    final bgTransparent = 0;

    for (var y = 0; y < lines.length; y++) {
      final line = lines[y];
      for (var x = 0; x < line.length; x++) {
        final char = line[x];
        if (char == ' ') continue; // Skip entirely, leave buffer untouched

        buffer.setAttributes(
          offset.dx.toInt() + x,
          offset.dy.toInt() + y,
          char: char,
          fg: fgColor.argb,
          bg: bgTransparent,
          modifiers: Modifier.bold,
        );
      }
    }
  }
}

class GlassOverlayApp extends StatefulWidget {
  final FireConfig config;
  const GlassOverlayApp({super.key, required this.config});

  @override
  State<GlassOverlayApp> createState() => _GlassOverlayAppState();
}

class _GlassOverlayAppState extends State<GlassOverlayApp> {
  Timer? _timer;
  bool _isGlitching = false;
  late final Stopwatch _stopwatch;
  double _lastTime = 0.0;
  double _glitchTimer = 0.0;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _stopwatch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      final now = _stopwatch.elapsedMilliseconds / 1000.0;
      final dt = now - _lastTime;
      _lastTime = now;

      _glitchTimer += dt;
      bool stateChanged = false;

      if (_isGlitching) {
        // Short burst: glitch lasts for 0.15 to 0.5 seconds
        if (_glitchTimer > 0.15 + _random.nextDouble() * 0.35) {
          _isGlitching = false;
          _glitchTimer = 0.0;
          stateChanged = true;
        } else {
          // Keep calling setState to scramble the glitch per-frame
          stateChanged = true;
        }
      } else {
        // Idle for 1.5s to 3.5s
        if (_glitchTimer > 1.5 + _random.nextDouble() * 2.0) {
          _isGlitching = true;
          _glitchTimer = 0.0;
          stateChanged = true;
        }
      }

      if (stateChanged) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: MetallicTextRender(config: widget.config),
    );

    if (_isGlitching) {
      content = EffectWidget(
        globalComposite:
            false, // Apply only to the text layer, leaving fire smooth
        effect: GlitchEffect(() {
          // Shift only some lines (30% chance) and shift them further
          if (_random.nextDouble() > 0.7) {
            return _random.nextInt(21) - 10; // Shift between -10 and +10
          }
          return 0;
        }),
        child: content,
      );
    }

    return Align(alignment: Alignment.center, child: content);
  }
}

// --- Carousel Selector ---

class CarouselSelector extends StatefulWidget implements Focusable {
  final SelectionController<String> controller;
  @override
  final bool focused;

  const CarouselSelector({
    super.key,
    required this.controller,
    this.focused = false,
  });

  @override
  State<CarouselSelector> createState() => _CarouselSelectorState();
}

class _CarouselSelectorState extends State<CarouselSelector> {
  late final FocusNode _focusNode;
  late final void Function() _listener;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(id: 'carousel_${widget.hashCode}');
    _listener = () {
      if (mounted) setState(() {});
    };
    widget.controller.addListener(_listener);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_listener);
    _focusNode.dispose();
    super.dispose();
  }

  void _prev() {
    int idx = widget.controller.selectedIndex - 1;
    if (idx < 0) idx = widget.controller.options.length - 1;
    widget.controller.selectedIndex = idx;
  }

  void _next() {
    int idx =
        (widget.controller.selectedIndex + 1) %
        widget.controller.options.length;
    widget.controller.selectedIndex = idx;
  }

  bool handleKeyEvent(term.KeyEvent event) {
    if (event.type == term.KeyType.left || event.key == 'h') {
      _prev();
      return true;
    } else if (event.type == term.KeyType.right || event.key == 'l') {
      _next();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final opt = widget.controller.selected;

    final style = _focusNode.hasFocus || widget.focused
        ? const Style(modifiers: Modifier.reverse, foreground: Colors.yellow)
        : const Style(modifiers: Modifier.bold, foreground: Colors.yellow);

    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (event) => handleKeyEvent(event),
      child: SizedBox(
        width: 22, // Fixed width for consistent alignment
        height: 1,
        child: Row([
          Button(
            text: '<',
            onPressed: _prev,
            style: style,
            focusedStyle: const Style(
              modifiers: Modifier.reverse,
              foreground: Colors.yellow,
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.center,
              child: Text(opt, style: style),
            ),
          ),
          Button(
            text: '>',
            onPressed: _next,
            style: style,
            focusedStyle: const Style(
              modifiers: Modifier.reverse,
              foreground: Colors.yellow,
            ),
          ),
        ]),
      ),
    );
  }
}

// --- Settings UI Layer ---

class SettingsApp extends StatefulWidget {
  final FireConfig config;
  const SettingsApp({super.key, required this.config});
  @override
  State<SettingsApp> createState() => _SettingsAppState();
}

class _SettingsAppState extends State<SettingsApp> {
  late final SelectionController<String> _themeCtrl;
  late final SelectionController<String> _fontCtrl;

  late final void Function() _listener;
  late final void Function() _configListener;

  @override
  void initState() {
    super.initState();
    _themeCtrl = SelectionController<String>(
      options: ['Classic', 'Toxic', 'Ice', 'Arcane', 'Neon', 'Ghost'],
      initialIndex: widget.config.themeIndex,
    );
    _fontCtrl = SelectionController<String>(
      options: ['Font 1', 'Font 2', 'Font 3', 'Font 4', 'Font 5'],
      initialIndex: widget.config.fontIndex,
    );
    _listener = () {
      setState(() {
        widget.config.themeIndex = _themeCtrl.selectedIndex;
        widget.config.fontIndex = _fontCtrl.selectedIndex;
      });
    };
    _themeCtrl.addListener(_listener);
    _fontCtrl.addListener(_listener);

    _configListener = () {
      if (!mounted) return;
      if (_fontCtrl.selectedIndex != widget.config.fontIndex) {
        _fontCtrl.selectedIndex = widget.config.fontIndex;
      }
      if (_themeCtrl.selectedIndex != widget.config.themeIndex) {
        _themeCtrl.selectedIndex = widget.config.themeIndex;
      }
      setState(() {});
    };
    widget.config.addListener(_configListener);
  }

  @override
  void dispose() {
    widget.config.removeListener(_configListener);
    _themeCtrl.removeListener(_listener);
    _fontCtrl.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border.all(Style(foreground: Colors.blue)),
        backgroundStyle: Style(background: Colors.black),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Column([
          const SizedBox(
            height: 1,
            child: Text(
              '🔥 FIRE CONTROLS (Press "s" to toggle)',
              style: Style(modifiers: Modifier.bold, foreground: Colors.yellow),
            ),
          ),
          const SizedBox(height: 1),
          const SizedBox(height: 1, child: Text('Flame Height')),
          SizedBox(
            height: 1,
            child: Slider(
              value: widget.config.flameHeight,
              min: 0.0,
              max: 1.0,
              onChanged: (v) {
                setState(() {
                  widget.config.flameHeight = v;
                });
              },
            ),
          ),
          const SizedBox(height: 1),
          const SizedBox(height: 1, child: Text('Simulation Speed')),
          SizedBox(
            height: 1,
            child: Slider(
              value: widget.config.speed,
              min: 0.1,
              max: 3.0,
              onChanged: (v) {
                setState(() {
                  widget.config.speed = v;
                });
              },
            ),
          ),
          const SizedBox(height: 1),
          const SizedBox(height: 1, child: Text('Wind Direction')),
          SizedBox(
            height: 1,
            child: Slider(
              value: widget.config.wind,
              min: -1.0,
              max: 1.0,
              onChanged: (v) {
                setState(() {
                  widget.config.wind = v;
                });
              },
            ),
          ),
          const SizedBox(height: 1),
          SizedBox(
            height: 1,
            child: Checkbox(
              label: 'Auto Animate Style',
              value: widget.config.autoAnimate,
              onChanged: (v) {
                setState(() {
                  widget.config.autoAnimate = v == true;
                });
              },
            ),
          ),
          const SizedBox(height: 1),
          const SizedBox(height: 1, child: Text('Theme')),
          Align(
            alignment: Alignment.centerLeft,
            child: CarouselSelector(controller: _themeCtrl, focused: false),
          ),
          const SizedBox(height: 1),
          const SizedBox(height: 1, child: Text('Font')),
          Align(
            alignment: Alignment.centerLeft,
            child: CarouselSelector(controller: _fontCtrl, focused: false),
          ),
        ]),
      ),
    );
  }
}

// --- Main Application with SceneManager ---

Future<void> runGlassCompositingShared(
  term.Terminal terminal, {
  bool isInline = false,
  void Function(Buffer)? onFrameRedrawn,
}) async {
  final sceneManager = SceneManager(
    terminal,
    renderingMode: isInline
        ? RenderingMode.inline
        : RenderingMode.alternateScreen,
  );
  sceneManager.enableMouseTracking = true;
  sceneManager.onFrameRedrawn = onFrameRedrawn;

  if (!isInline) {
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();
  }

  final prefs = await SharedPreferences.getInstance();
  final config = FireConfig(prefs);
  config.flameHeight = 1.0;
  config.speed = 1.5;

  // 1. Bottom Layer: Fire
  final fireRunner = PromptRunner(
    terminal: terminal,
    widget: FireApp(config: config),
    alternateScreen: false,
    mode: ExecutionMode.managed,
    onFramePainted: (_) => sceneManager.scheduleRender(),
  );
  final fireLayer = SceneLayer(
    renderer: fireRunner,
    sizing: LayerSizing.fullscreen,
    zIndex: 10,
  );
  sceneManager.layers.add(fireLayer);
  fireRunner.run().catchError((_) {});

  // 2. Middle Layer: Glass Overlay Text
  final glassRunner = PromptRunner(
    terminal: terminal,
    widget: GlassOverlayApp(config: config),
    alternateScreen: false,
    mode: ExecutionMode.managed,
    onFramePainted: (_) => sceneManager.scheduleRender(),
  );
  final glassLayer = SceneLayer(
    renderer: glassRunner,
    sizing: LayerSizing.fullscreen,
    zIndex: 20,
  );
  sceneManager.layers.add(glassLayer);
  glassRunner.run().catchError((_) {});

  // 3. Top Layer: Settings Window
  final settingsRunner = PromptRunner(
    terminal: terminal,
    widget: SettingsApp(config: config),
    alternateScreen: false,
    mode: ExecutionMode.managed,
    onFramePainted: (_) => sceneManager.scheduleRender(),
  );
  final settingsLayer = SceneLayer(
    renderer: settingsRunner,
    sizing: LayerSizing.fixed,
    x: 2,
    y: 2,
    width: 42,
    height: 20,
    zIndex: 30,
    draggable: false,
    resizable: false,
  );
  settingsRunner.run().catchError((_) {});

  sceneManager.focusedLayer = glassLayer;
  bool settingsVisible = false;

  final fontTimer = Timer.periodic(const Duration(seconds: 10), (t) {
    if (config.autoAnimate) {
      config.fontIndex = (config.fontIndex + 1) % 5;
    }
  });

  final themeTimer = Timer.periodic(const Duration(seconds: 15), (t) {
    if (config.autoAnimate) {
      config.themeIndex = (config.themeIndex + 1) % 6;
    }
  });

  final windTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
    config.wind = sin(t.tick / 20.0);
  });

  try {
    await for (final event in terminal.events) {
      if (event is term.KeyEvent) {
        if (event.key == 'q' ||
            event.key == 'Q' ||
            event.key == '\x03' ||
            event.logicalKey == term.TermKey.controlC) {
          break;
        }
        if (event.key == 's' || event.key == 'S') {
          settingsVisible = !settingsVisible;
          if (settingsVisible) {
            sceneManager.layers.add(settingsLayer);
            sceneManager.focusedLayer = settingsLayer;
          } else {
            sceneManager.layers.remove(settingsLayer);
            sceneManager.focusedLayer = glassLayer;
          }
          sceneManager.scheduleRender();
        }
      }
    }
  } finally {
    fontTimer.cancel();
    themeTimer.cancel();
    windTimer.cancel();
    settingsRunner.abort();
    glassRunner.abort();
    fireRunner.abort();
    sceneManager.dispose();
    if (!isInline) {
      terminal.exitAlternateScreen();
      terminal.showCursor();
      terminal.disableMouseTracking();
    }
  }
}
