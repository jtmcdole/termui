import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/perf/tracer.dart';

import 'backend.dart';
import 'rendering/atlas.dart';
import 'rendering/painter.dart';
import 'util/file_saver.dart';
import 'util/font_helper.dart';

/// A widget that embeds a `termui` TUI application within Flutter.
///
/// It initializes a [FlutterTerminal], triggers the event loop using the
/// [onRun] callback, and sets up a [PrivateTuiView] to handle painting and focus.
///
/// ### Example Usage
///
/// ```dart
/// Terminal(
///   fontSize: 14.0,
///   fontFamily: 'Cascadia Code',
///   backgroundColor: Colors.black,
///   onRun: (terminal, drawFrame) async {
///     final app = App(backend: terminal.backend);
///     app.run((frame) {
///       frame.write(0, 0, 'Welcome to the Embedded TUI!');
///     });
///   },
/// )
/// ```
///
/// ### Properties and Configuration
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `terminal` | [FlutterTerminal]? | Optional custom terminal instance. |
/// | `onRun` | `Future<void> Function(...)` | Callback executing the TUI event loop. |
/// | `fontSize` | [double] | The text rendering font size. Defaults to `13.0`. |
/// | `fontFamily` | [String] | Monospaced font family for rendering cells. |
/// | `backgroundColor` | [Color] | The background color of the terminal view. |
class Terminal extends StatefulWidget {
  /// Optional custom terminal instance.
  final FlutterTerminal? terminal;

  /// Callback executing the TUI event loop, providing the terminal and draw dispatcher.
  final Future<void> Function(
    FlutterTerminal terminal,
    void Function(Buffer) drawFrame,
  )
  onRun;

  /// The text rendering font size. Defaults to `13.0`.
  final double fontSize;

  /// Monospaced font family for rendering cells.
  final String fontFamily;

  /// Fallback monospaced font families.
  final List<String>? fontFamilyFallback;

  /// The background color of the terminal view.
  final Color backgroundColor;

  /// Creates a [Terminal] view bounding the TUI app hierarchy.
  const Terminal({
    super.key,
    this.terminal,
    required this.onRun,
    this.fontSize = 13.0,
    this.fontFamily = 'Cascadia Mono',
    this.fontFamilyFallback,
    this.backgroundColor = Colors.black,
  });

  @override
  State<Terminal> createState() => _TerminalState();
}

class _TerminalState extends State<Terminal> {
  late final FlutterTerminal _terminal;
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    _terminal =
        widget.terminal ?? FlutterTerminal(initialFontSize: widget.fontSize);
  }

  @override
  void dispose() {
    if (widget.terminal == null) {
      _terminal.dispose();
    }
    super.dispose();
  }

  void _startLoop(void Function(Buffer) drawFrame) async {
    if (_isRunning) return;
    _isRunning = true;
    try {
      await widget.onRun(_terminal, drawFrame);
    } finally {
      _isRunning = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PrivateTuiView(
      terminal: _terminal,
      fontSize: widget.fontSize,
      fontFamily: widget.fontFamily,
      fontFamilyFallback: widget.fontFamilyFallback,
      backgroundColor: widget.backgroundColor,
      onInit: _startLoop,
    );
  }
}

/// The internal widget that manages drawing, keyboard focus, and mouse input.
///
/// It listens for pointer gestures (tap, drag, hover) and hardware keyboard
/// events, translating them into `termui` input events. It also holds the
/// [GlyphAtlas] texture atlas and schedules custom paints when a new [Buffer]
/// is received.
///
/// Key functions:
/// 1. Manages a [FocusNode] to direct hardware keyboard inputs.
/// 2. Performs hit-testing to map mouse positions to terminal grid cells.
/// 3. Builds a fallback dictionary of painters for characters not in the atlas.
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `terminal` | [FlutterTerminal] | The terminal logic controller. |
/// | `onInit` | `Function(void Function(Buffer))` | Callback to hook frame rendering. |
/// | `fontSize` | [double] | Monospaced font height scaling factor. |
/// | `fontFamily` | [String] | Active typeface family. |
/// | `backgroundColor` | [Color] | Backdrop style filling the grid viewport. |
class PrivateTuiView extends StatefulWidget {
  /// The internal terminal logic controller backing the UI events.
  final FlutterTerminal terminal;

  /// Hook to register the native frame drawing callback on initialization.
  final void Function(void Function(Buffer) onDrawFrame) onInit;

  /// The scaled monospaced font point height.
  final double fontSize;

  /// The configured monospaced text typeface label.
  final String fontFamily;

  /// Fallback monospaced font families.
  final List<String>? fontFamilyFallback;

  /// General terminal canvas background color filler.
  final Color backgroundColor;

  /// Internal widget constructor binding the terminal state to rendering hooks.
  const PrivateTuiView({
    super.key,
    required this.terminal,
    required this.onInit,
    this.fontSize = 13,
    this.fontFamily = 'Cascadia Mono',
    this.fontFamilyFallback,
    this.backgroundColor = Colors.black,
  });

  @override
  State<PrivateTuiView> createState() => _PrivateTuiViewState();
}

class _PrivateTuiViewState extends State<PrivateTuiView> {
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _boundaryKey = GlobalKey();
  GlyphAtlas? _atlas;
  Buffer? _currentBuffer;
  StreamSubscription<String?>? _mouseCursorSubscription;
  MouseCursor _currentCursor = SystemMouseCursors.basic;

  final Map<(String, bool, bool, Color), TextPainter> _fallbackPainters = {};
  final Set<String> _pendingGlyphs = {};
  final Set<String> _processingGlyphs = {};
  bool _isUpdatingAtlas = false;

  late double _fontSize;
  double get fontSize => _fontSize;
  int _atlasGenerationId = 0;
  StreamSubscription<double>? _fontSizeSubscription;

  static final int _traceRecreateAtlasId = Tracer.registerString(
    'TuiView:recreateAtlas',
  );
  static final int _traceFontSizeChangedId = Tracer.registerString(
    'TuiView:fontSizeChanged',
  );
  static final int _traceTriggerAtlasUpdateId = Tracer.registerString(
    'TuiView:triggerAtlasUpdate',
  );

  void _handleSystemFontsChange() {
    if (mounted) {
      _recreateAtlas();
    }
  }

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_handleSystemFontsChange);
    _fontSize = widget.terminal.fontSize;
    _fontSizeSubscription = widget.terminal.watchFontSize().listen((newSize) {
      if (mounted) {
        Tracer.record(
          _traceFontSizeChangedId,
          Phase.instant,
          TraceCategory.layout,
        );
        setState(() {
          _fontSize = newSize;
        });
        _recreateAtlas();
      }
    });

    _mouseCursorSubscription = widget.terminal.mouseCursorChanges.listen((
      cursorName,
    ) {
      if (mounted) {
        setState(() {
          _currentCursor = _mapOsc22ToSystemCursor(cursorName);
        });
      }
    });

    _initAtlasAndLoop();
  }

  void _initAtlasAndLoop() async {
    await _recreateAtlas();
    if (mounted) {
      widget.onInit((buffer) {
        if (mounted) {
          scheduleMicrotask(() {
            if (mounted) {
              _updateFallbackPainters(buffer);
              setState(() {
                _currentBuffer = buffer;
              });
            }
          });
        }
      });
    }

    await waitForFontsToLoad();
    if (mounted) {
      _recreateAtlas();
    }
  }

  Future<void> _recreateAtlas() async {
    final genId = ++_atlasGenerationId;
    Tracer.record(_traceRecreateAtlasId, Phase.begin, TraceCategory.paint);
    _fallbackPainters.clear();
    _pendingGlyphs.clear();
    _processingGlyphs.clear();
    _isUpdatingAtlas = false;

    final newAtlas = await GlyphAtlasGenerator.generate(
      fontSize: _fontSize,
      fontFamily: widget.fontFamily,
      fontFamilyFallback: widget.fontFamilyFallback,
    );

    if (!mounted) return;
    if (genId == _atlasGenerationId) {
      setState(() {
        _atlas = newAtlas;
      });
    }
    Tracer.record(_traceRecreateAtlasId, Phase.end, TraceCategory.paint);
  }

  MouseCursor _mapOsc22ToSystemCursor(String? cursorName) {
    if (cursorName == null || cursorName.isEmpty || cursorName == 'default') {
      return SystemMouseCursors.basic;
    }
    return switch (cursorName) {
      'text' => SystemMouseCursors.text,
      'pointer' => SystemMouseCursors.click,
      'crosshair' => SystemMouseCursors.precise,
      'help' => SystemMouseCursors.help,
      'progress' => SystemMouseCursors.progress,
      'wait' => SystemMouseCursors.wait,
      'move' => SystemMouseCursors.move,
      'not-allowed' => SystemMouseCursors.forbidden,
      'grab' => SystemMouseCursors.grab,
      'grabbing' => SystemMouseCursors.grabbing,
      'none' => SystemMouseCursors.none,
      'alias' => SystemMouseCursors.alias,
      'copy' => SystemMouseCursors.copy,
      'cell' => SystemMouseCursors.cell,
      'no-drop' => SystemMouseCursors.noDrop,
      'zoom-in' => SystemMouseCursors.zoomIn,
      'zoom-out' => SystemMouseCursors.zoomOut,
      'ns-resize' => SystemMouseCursors.resizeUpDown,
      'ew-resize' => SystemMouseCursors.resizeLeftRight,
      'all-scroll' => SystemMouseCursors.allScroll,
      _ => SystemMouseCursors.basic,
    };
  }

  @override
  void didUpdateWidget(PrivateTuiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      _fontSizeSubscription?.cancel();
      _fontSize = widget.terminal.fontSize;
      _fontSizeSubscription = widget.terminal.watchFontSize().listen((newSize) {
        if (mounted) {
          Tracer.record(
            _traceFontSizeChangedId,
            Phase.instant,
            TraceCategory.layout,
          );
          setState(() {
            _fontSize = newSize;
          });
          _recreateAtlas();
        }
      });
      _recreateAtlas();
    } else if (oldWidget.fontSize != widget.fontSize) {
      widget.terminal.setFontSize(widget.fontSize);
    } else if (oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.fontFamilyFallback != widget.fontFamilyFallback) {
      _recreateAtlas();
    }
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(
      _handleSystemFontsChange,
    );
    _fontSizeSubscription?.cancel();
    _mouseCursorSubscription?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _updateFallbackPainters(Buffer buffer) {
    final atlas = _atlas;
    if (atlas == null) return;

    final total = buffer.width * buffer.height;
    final width = buffer.width;
    for (var i = 0; i < total; i++) {
      final char = buffer.characters[i];
      if (char.isNotEmpty &&
          char != ' ' &&
          !atlas.charRects.containsKey(char)) {
        final x = i % width;
        final y = i ~/ width;
        final mods = buffer.getModifiers(x, y);
        final isReverse = Modifier.has(mods, Modifier.reverse);
        final fgVal = isReverse
            ? buffer.getBackground(x, y)
            : buffer.getForeground(x, y);
        final color = fgVal != 0
            ? Color(fgVal)
            : (isReverse ? Colors.black : Colors.white);
        final isBold = Modifier.has(mods, Modifier.bold);
        final isDim = Modifier.has(mods, Modifier.dim);

        final key = (char, isBold, isDim, color);
        if (!_fallbackPainters.containsKey(key)) {
          final textStyle = TextStyle(
            fontFamily: widget.fontFamily,
            fontFamilyFallback: widget.fontFamilyFallback,
            fontSize: _fontSize,
            color: color,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            height: 1.0,
          );
          final textSpan = TextSpan(text: char, style: textStyle);
          final textPainter = TextPainter(
            text: textSpan,
            textDirection: TextDirection.ltr,
          );
          textPainter.layout();
          _fallbackPainters[key] = textPainter;
        }
      }
    }
  }

  void _onMissingGlyphs(List<String> glyphs) {
    if (_atlas == null) return;
    var needsUpdate = false;
    for (final glyph in glyphs) {
      if (!_pendingGlyphs.contains(glyph) &&
          !_processingGlyphs.contains(glyph) &&
          !_atlas!.charRects.containsKey(glyph)) {
        _pendingGlyphs.add(glyph);
        needsUpdate = true;
      }
    }
    if (needsUpdate) {
      _triggerAtlasUpdate();
    }
  }

  void _triggerAtlasUpdate() async {
    if (_isUpdatingAtlas || _pendingGlyphs.isEmpty || _atlas == null) return;
    _isUpdatingAtlas = true;
    final genId = _atlasGenerationId;
    Tracer.record(_traceTriggerAtlasUpdateId, Phase.begin, TraceCategory.paint);

    final batch = _pendingGlyphs.toList();
    _pendingGlyphs.removeAll(batch);
    _processingGlyphs.addAll(batch);

    try {
      await Future.microtask(() {});
      if (!mounted || genId != _atlasGenerationId) return;

      final newAtlas = await _atlas!.addGlyphs(batch);
      if (mounted && genId == _atlasGenerationId) {
        setState(() {
          _atlas = newAtlas;
        });
      }
    } finally {
      _processingGlyphs.removeAll(batch);
      _isUpdatingAtlas = false;
      Tracer.record(_traceTriggerAtlasUpdateId, Phase.end, TraceCategory.paint);
      if (_pendingGlyphs.isNotEmpty && genId == _atlasGenerationId) {
        _triggerAtlasUpdate();
      }
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final key = event.logicalKey;

      if (key == LogicalKeyboardKey.f12) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          _recreateAtlas();
        } else {
          _takeScreenshot();
        }
        return;
      }

      final mods = <term.Modifier>{};

      if (HardwareKeyboard.instance.isShiftPressed) {
        mods.add(term.Modifier.shift);
      }
      if (HardwareKeyboard.instance.isAltPressed) {
        mods.add(term.Modifier.alt);
      }
      if (HardwareKeyboard.instance.isControlPressed) {
        mods.add(term.Modifier.control);
      }
      if (HardwareKeyboard.instance.isMetaPressed) {
        mods.add(term.Modifier.meta);
      }

      term.InputEvent? termEvent;

      if (key == LogicalKeyboardKey.arrowUp) {
        termEvent = term.KeyEvent('up', term.KeyType.up, modifiers: mods);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        termEvent = term.KeyEvent('down', term.KeyType.down, modifiers: mods);
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        termEvent = term.KeyEvent('left', term.KeyType.left, modifiers: mods);
      } else if (key == LogicalKeyboardKey.arrowRight) {
        termEvent = term.KeyEvent('right', term.KeyType.right, modifiers: mods);
      } else if (key == LogicalKeyboardKey.home) {
        termEvent = term.KeyEvent('home', term.KeyType.home, modifiers: mods);
      } else if (key == LogicalKeyboardKey.end) {
        termEvent = term.KeyEvent('end', term.KeyType.end, modifiers: mods);
      } else if (key == LogicalKeyboardKey.delete) {
        termEvent = term.KeyEvent(
          'delete',
          term.KeyType.delete,
          modifiers: mods,
        );
      } else if (key == LogicalKeyboardKey.backspace) {
        termEvent = term.KeyEvent(
          'backspace',
          term.KeyType.backspace,
          modifiers: mods,
        );
      } else if (key == LogicalKeyboardKey.pageUp) {
        termEvent = term.KeyEvent(
          'pageUp',
          term.KeyType.pageUp,
          modifiers: mods,
        );
      } else if (key == LogicalKeyboardKey.pageDown) {
        termEvent = term.KeyEvent(
          'pageDown',
          term.KeyType.pageDown,
          modifiers: mods,
        );
      } else if (key == LogicalKeyboardKey.escape) {
        termEvent = term.KeyEvent(
          'escape',
          term.KeyType.escape,
          modifiers: mods,
        );
      } else if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        termEvent = term.KeyEvent('\n', term.KeyType.enter, modifiers: mods);
      } else if (key == LogicalKeyboardKey.tab) {
        if (mods.contains(term.Modifier.shift)) {
          termEvent = term.KeyEvent(
            'backtab',
            term.KeyType.tab,
            modifiers: mods,
          );
        } else {
          termEvent = term.KeyEvent('\t', term.KeyType.tab, modifiers: mods);
        }
      } else if (key == LogicalKeyboardKey.f1) {
        termEvent = term.KeyEvent('f1', term.KeyType.f1, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f2) {
        termEvent = term.KeyEvent('f2', term.KeyType.f2, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f3) {
        termEvent = term.KeyEvent('f3', term.KeyType.f3, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f4) {
        termEvent = term.KeyEvent('f4', term.KeyType.f4, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f5) {
        termEvent = term.KeyEvent('f5', term.KeyType.f5, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f6) {
        termEvent = term.KeyEvent('f6', term.KeyType.f6, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f7) {
        termEvent = term.KeyEvent('f7', term.KeyType.f7, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f8) {
        termEvent = term.KeyEvent('f8', term.KeyType.f8, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f9) {
        termEvent = term.KeyEvent('f9', term.KeyType.f9, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f10) {
        termEvent = term.KeyEvent('f10', term.KeyType.f10, modifiers: mods);
      } else if (key == LogicalKeyboardKey.f11) {
        termEvent = term.KeyEvent('f11', term.KeyType.f11, modifiers: mods);
      } else if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.numpadAdd) {
        termEvent = term.KeyEvent(
          key == LogicalKeyboardKey.numpadAdd ? '+' : '=',
          term.KeyType.character,
          modifiers: mods,
        );
      } else if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        termEvent = term.KeyEvent(
          key == LogicalKeyboardKey.numpadSubtract ? '-' : '-',
          term.KeyType.character,
          modifiers: mods,
        );
      } else if (event.character != null && event.character!.isNotEmpty) {
        final char = event.character!;
        if (char == '\n' || char == '\r' || char == '\r\n') {
          termEvent = term.KeyEvent('\n', term.KeyType.enter, modifiers: mods);
        } else {
          termEvent = term.KeyEvent(
            char,
            term.KeyType.character,
            modifiers: mods,
          );
        }
      } else if (key.keyLabel.length == 1) {
        termEvent = term.KeyEvent(
          key.keyLabel.toLowerCase(),
          term.KeyType.character,
          modifiers: mods,
        );
      }

      if (termEvent != null) {
        widget.terminal.injectEvent(termEvent);
      }
    }
  }

  void _takeScreenshot() async {
    try {
      final timestamp = clock.now().millisecondsSinceEpoch;
      String? screenshotBasename;
      String? atlasBasename;
      String? coordinatesBasename;

      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary != null) {
        final image = await boundary.toImage(pixelRatio: 2.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          final pngBytes = byteData.buffer.asUint8List();
          screenshotBasename = await saveFile(
            'screenshot_$timestamp.png',
            pngBytes,
          );
        }
      }

      final atlas = _atlas;
      if (atlas != null) {
        final byteData = await atlas.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (byteData != null) {
          final pngBytes = byteData.buffer.asUint8List();
          atlasBasename = await saveFile('atlas_$timestamp.png', pngBytes);
        }

        final rectsMap = atlas.charRects.map((key, value) {
          return MapEntry(
            key.runes
                .map(
                  (r) =>
                      'U+${r.toRadixString(16).padLeft(4, '0').toUpperCase()}',
                )
                .join(' '),
            {
              'char': key,
              'left': value.left,
              'top': value.top,
              'right': value.right,
              'bottom': value.bottom,
              'width': value.width,
              'height': value.height,
            },
          );
        });

        final atlasJsonData = const JsonEncoder.withIndent(
          '  ',
        ).convert(rectsMap);
        final atlasJsonBytes = utf8.encode(atlasJsonData);
        await saveFile('atlas_table_$timestamp.json', atlasJsonBytes);
      }

      final buffer = _currentBuffer;
      if (buffer != null && atlas != null) {
        final Map<String, dynamic> data = {
          'timestamp': timestamp,
          'cols': buffer.width,
          'rows': buffer.height,
          'cellWidth': atlas.cellWidth,
          'cellHeight': atlas.cellHeight,
          'cells': [],
        };

        final cellsList = data['cells'] as List;
        for (var y = 0; y < buffer.height; y++) {
          final rowOffset = y * buffer.width;
          for (var x = 0; x < buffer.width; x++) {
            final idx = rowOffset + x;
            final char = buffer.characters[idx];
            final fg = buffer.getForeground(x, y);
            final bg = buffer.getBackground(x, y);
            final mods = buffer.getModifiers(x, y);

            final rect = atlas.charRects[char];
            final cellData = {
              'x': x,
              'y': y,
              'char': char,
              'fg': fg != 0
                  ? '0x${fg.toRadixString(16).padLeft(8, '0').toUpperCase()}'
                  : null,
              'bg': bg != 0
                  ? '0x${bg.toRadixString(16).padLeft(8, '0').toUpperCase()}'
                  : null,
              'modifiers': mods,
            };
            if (rect != null) {
              cellData['atlasRect'] = {
                'left': rect.left,
                'top': rect.top,
                'right': rect.right,
                'bottom': rect.bottom,
              };
            }
            cellsList.add(cellData);
          }
        }

        final jsonData = const JsonEncoder.withIndent('  ').convert(data);
        final bytes = utf8.encode(jsonData);
        coordinatesBasename = await saveFile(
          'coordinates_$timestamp.json',
          bytes,
        );
      }

      if (mounted) {
        final savedFiles = <String?>[
          screenshotBasename,
          atlasBasename,
          atlasBasename
              ?.replaceFirst('atlas_', 'atlas_table_')
              .replaceAll('.png', '.json'),
          coordinatesBasename,
        ].whereType<String>().toList();

        final String message;
        if (savedFiles.isNotEmpty) {
          message = 'Saved: ${savedFiles.join(', ')}';
        } else {
          message = 'No files saved.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving screenshot/atlas/coordinates: $e'),
          ),
        );
      }
    }
  }

  void _handlePointerEvent(PointerEvent event, Size layoutSize) {
    final cellWidth = _atlas!.cellWidth;
    final cellHeight = _atlas!.cellHeight;

    final double xPos = event.localPosition.dx;
    final double yPos = event.localPosition.dy;

    final col = (xPos / cellWidth).floor();
    final row = (yPos / cellHeight).floor();

    final maxCol = (layoutSize.width / cellWidth).floor();
    final maxRow = (layoutSize.height / cellHeight).floor();

    final clampedCol = col.clamp(0, maxCol - 1);
    final clampedRow = row.clamp(0, maxRow - 1);

    term.MouseButton termuiButton = term.MouseButton.none;
    term.MouseEventType termuiType = term.MouseEventType.move;

    if (event is PointerDownEvent) {
      if (event.buttons & kSecondaryMouseButton != 0) {
        termuiButton = term.MouseButton.right;
      } else if (event.buttons & kMiddleMouseButton != 0) {
        termuiButton = term.MouseButton.middle;
      } else {
        termuiButton = term.MouseButton.left;
      }
      termuiType = term.MouseEventType.press;
    } else if (event is PointerMoveEvent) {
      if (event.down) {
        if (event.buttons & kSecondaryMouseButton != 0) {
          termuiButton = term.MouseButton.right;
        } else if (event.buttons & kMiddleMouseButton != 0) {
          termuiButton = term.MouseButton.middle;
        } else {
          termuiButton = term.MouseButton.left;
        }
        termuiType = term.MouseEventType.drag;
      } else {
        termuiButton = term.MouseButton.none;
        termuiType = term.MouseEventType.move;
      }
    } else if (event is PointerUpEvent) {
      termuiButton = term.MouseButton.left;
      termuiType = term.MouseEventType.release;
    } else if (event is PointerScrollEvent) {
      termuiButton = event.scrollDelta.dy < 0
          ? term.MouseButton.wheelUp
          : term.MouseButton.wheelDown;
      termuiType = term.MouseEventType.press;
    }

    final mods = <term.Modifier>{};
    if (HardwareKeyboard.instance.isShiftPressed) {
      mods.add(term.Modifier.shift);
    }
    if (HardwareKeyboard.instance.isAltPressed) {
      mods.add(term.Modifier.alt);
    }
    if (HardwareKeyboard.instance.isControlPressed) {
      mods.add(term.Modifier.control);
    }
    if (HardwareKeyboard.instance.isMetaPressed) {
      mods.add(term.Modifier.meta);
    }

    widget.terminal.injectEvent(
      term.MouseEvent(
        x: clampedCol + 1,
        y: clampedRow + 1,
        button: termuiButton,
        type: termuiType,
        modifiers: mods,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_atlas == null) {
      return Scaffold(
        backgroundColor: widget.backgroundColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth = _atlas!.cellWidth;
        final cellHeight = _atlas!.cellHeight;

        final cols = (constraints.maxWidth / cellWidth).floor();
        final rows = (constraints.maxHeight / cellHeight).floor();

        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.terminal.updateSize(Point(cols, rows));
        });

        final layoutSize = Size(cols * cellWidth, rows * cellHeight);

        return Scaffold(
          backgroundColor: widget.backgroundColor,
          body: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: (node, event) {
              _handleKeyEvent(event);
              return KeyEventResult.handled;
            },
            child: Center(
              child: RepaintBoundary(
                key: _boundaryKey,
                child: MouseRegion(
                  cursor: _currentCursor,
                  child: Listener(
                    onPointerDown: (e) => _handlePointerEvent(e, layoutSize),
                    onPointerMove: (e) => _handlePointerEvent(e, layoutSize),
                    onPointerHover: (e) => _handlePointerEvent(e, layoutSize),
                    onPointerUp: (e) => _handlePointerEvent(e, layoutSize),
                    onPointerSignal: (signal) {
                      if (signal is PointerScrollEvent) {
                        _handlePointerEvent(signal, layoutSize);
                      }
                    },
                    child: Container(
                      width: layoutSize.width,
                      height: layoutSize.height,
                      color: widget.backgroundColor,
                      child: _currentBuffer == null
                          ? const SizedBox()
                          : CustomPaint(
                              size: layoutSize,
                              painter: TuiAtlasPainter(
                                buffer: _currentBuffer!,
                                atlas: _atlas!,
                                fontFamily: widget.fontFamily,
                                fontFamilyFallback: widget.fontFamilyFallback,
                                fallbackPainters: _fallbackPainters,
                                onMissingGlyphs: _onMissingGlyphs,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
