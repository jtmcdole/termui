import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';

import '../util/font_helper.dart';
import 'atlas.dart';
import 'painter.dart';

/// Shared GPU texture atlas and bounded fallback/ligature painter controller.
///
/// Multiple `TerminalSurface` panes can share a single [GlyphAtlasController]
/// so they rasterize from one shared [GlyphAtlas] GPU image. Superseded
/// [GlyphAtlas] instances and evicted [TextPainter] caches are disposed in a
/// post-frame callback after [notifyListeners] so sibling panes never paint a
/// disposed texture or painter mid-frame.
final class GlyphAtlasController extends ChangeNotifier {
  /// Maximum cached fallback [TextPainter] entries before LRU eviction.
  static const int maxFallbackPainters = 256;

  /// Maximum cached ligature [TextPainter] entries before LRU eviction.
  static const int maxLigaturePainters = 128;

  static final int _traceRecreateAtlasId = Tracer.registerString(
    'GlyphAtlasController:recreateAtlas',
  );
  static final int _traceTriggerAtlasUpdateId = Tracer.registerString(
    'GlyphAtlasController:triggerAtlasUpdate',
  );

  double _fontSize;
  String _fontFamily;
  List<String>? _fontFamilyFallback;
  double _devicePixelRatio;

  GlyphAtlas? _atlas;
  int _generationId = 0;
  bool _isDisposed = false;
  bool _isUpdatingAtlas = false;
  bool _webFontsWaitStarted = false;
  bool _postFrameDisposalScheduled = false;
  Future<void>? _initFuture;

  int _createdAtlasCount = 0;
  int _disposedAtlasCount = 0;

  final Set<(String, GlyphStyleVariant)> _pendingGlyphs = {};
  final Set<(String, GlyphStyleVariant)> _processingGlyphs = {};
  final Map<(String, bool, bool, bool, Color), TextPainter> _fallbackPainters =
      {};
  final Map<(String, bool, bool, Color), TextPainter> _ligaturePainters = {};
  final Set<GlyphAtlas> _pendingAtlasDisposals = Set<GlyphAtlas>.identity();
  final List<TextPainter> _pendingPainterDisposals = [];

  /// Creates a shared [GlyphAtlasController] for the given font metrics.
  GlyphAtlasController({
    double fontSize = 13.0,
    String fontFamily = 'Cascadia Mono',
    List<String>? fontFamilyFallback,
    double devicePixelRatio = 1.0,
  }) : _fontSize = _sanitizePositive(fontSize, 13.0),
       _fontFamily = fontFamily,
       _fontFamilyFallback = fontFamilyFallback == null
           ? null
           : List<String>.unmodifiable(fontFamilyFallback),
       _devicePixelRatio = _sanitizePositive(devicePixelRatio, 1.0) {
    PaintingBinding.instance.systemFonts.addListener(_handleSystemFontsChange);
  }

  static double _sanitizePositive(double value, double fallback) =>
      (value.isFinite && value > 0.0) ? value : fallback;

  /// Currently active shared [GlyphAtlas], or `null` before initial bake completes.
  GlyphAtlas? get atlas => _atlas;

  /// Current point size used to rasterize glyphs.
  double get fontSize => _fontSize;

  /// Primary monospaced font family.
  String get fontFamily => _fontFamily;

  /// Unmodifiable fallback font families, if configured.
  List<String>? get fontFamilyFallback => _fontFamilyFallback;

  /// Device pixel ratio used when rasterizing the current atlas.
  double get devicePixelRatio => _devicePixelRatio;

  /// Whether [dispose] has been called on this controller.
  bool get isDisposed => _isDisposed;

  /// Monotonically incremented generation counter for atlas recreations.
  int get generationId => _generationId;

  /// Current rounded logical cell dimensions `(width, height)`.
  (int, int) get cellPixelSize {
    final active = _atlas;
    if (active == null) return (9, 18);
    return (
      active.cellWidth.round().clamp(1, 1024),
      active.cellHeight.round().clamp(1, 1024),
    );
  }

  /// Current exact logical cell dimensions `(width, height)`.
  (double, double) get exactCellPixelSize {
    final active = _atlas;
    if (active == null) return (9.0, 18.0);
    return (active.cellWidth, active.cellHeight);
  }

  /// Bounded cache of fallback [TextPainter] instances shared with [TuiAtlasPainter].
  Map<(String, bool, bool, bool, Color), TextPainter> get fallbackPainters =>
      _fallbackPainters;

  /// Bounded cache of multi-cell ligature [TextPainter] instances shared with [TuiAtlasPainter].
  Map<(String, bool, bool, Color), TextPainter> get ligaturePainters =>
      _ligaturePainters;

  /// Total [GlyphAtlas] textures created by this controller (testing helper).
  @visibleForTesting
  int get debugCreatedAtlasCount => _createdAtlasCount;

  /// Total [GlyphAtlas] textures disposed by this controller (testing helper).
  @visibleForTesting
  int get debugDisposedAtlasCount => _disposedAtlasCount;

  /// Number of superseded [GlyphAtlas] instances awaiting post-frame disposal.
  @visibleForTesting
  int get debugPendingAtlasDisposalCount => _pendingAtlasDisposals.length;

  void _handleSystemFontsChange() {
    if (_isDisposed) return;
    unawaited(recreateAtlas());
  }

  /// Starts initial [GlyphAtlas] generation once; concurrent callers await the same [Future].
  Future<void> ensureInitialized() {
    if (_isDisposed) return Future<void>.value();
    return _initFuture ??= _initializeAsync();
  }

  Future<void> _initializeAsync() async {
    await recreateAtlas();
    if (kIsWeb && !_isDisposed && !_webFontsWaitStarted) {
      _webFontsWaitStarted = true;
      unawaited(
        waitForFontsToLoad().then((_) {
          if (!_isDisposed) {
            return recreateAtlas();
          }
        }),
      );
    }
  }

  /// Updates font configuration or device pixel ratio and regenerates the atlas if changed.
  Future<void> updateConfig({
    double? fontSize,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    bool updateFallbackList = false,
    double? devicePixelRatio,
  }) async {
    if (_isDisposed) return;
    var changed = false;

    if (fontSize != null) {
      final safeSize = _sanitizePositive(fontSize, _fontSize);
      if (_fontSize != safeSize) {
        _fontSize = safeSize;
        changed = true;
      }
    }
    if (fontFamily != null && _fontFamily != fontFamily) {
      _fontFamily = fontFamily;
      changed = true;
    }
    if (updateFallbackList &&
        !listEquals(_fontFamilyFallback, fontFamilyFallback)) {
      _fontFamilyFallback = fontFamilyFallback == null
          ? null
          : List<String>.unmodifiable(fontFamilyFallback);
      changed = true;
    }
    if (devicePixelRatio != null) {
      final safeDpr = _sanitizePositive(devicePixelRatio, _devicePixelRatio);
      if (_devicePixelRatio != safeDpr) {
        _devicePixelRatio = safeDpr;
        changed = true;
      }
    }

    if (changed) {
      await recreateAtlas();
    }
  }

  /// Updates [fontSize] and recreates the shared atlas if changed.
  Future<void> setFontSize(double fontSize) => updateConfig(fontSize: fontSize);

  /// Updates [devicePixelRatio] and recreates the shared atlas if changed.
  Future<void> setDevicePixelRatio(double devicePixelRatio) =>
      updateConfig(devicePixelRatio: devicePixelRatio);

  /// Regenerates the shared [GlyphAtlas] and defers disposal of the superseded texture.
  Future<void> recreateAtlas() async {
    if (_isDisposed) return;
    final genId = ++_generationId;
    Tracer.record(_traceRecreateAtlasId, Phase.begin, TraceCategory.paint);
    clearPainterCaches();
    _pendingGlyphs.clear();
    _processingGlyphs.clear();
    _isUpdatingAtlas = false;

    final newAtlas = await GlyphAtlasGenerator.generate(
      fontSize: _fontSize,
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFamilyFallback,
      devicePixelRatio: _devicePixelRatio,
    );

    if (_isDisposed || genId != _generationId) {
      newAtlas.dispose();
      Tracer.record(_traceRecreateAtlasId, Phase.end, TraceCategory.paint);
      return;
    }

    _createdAtlasCount++;
    _swapAtlas(newAtlas);
    Tracer.record(_traceRecreateAtlasId, Phase.end, TraceCategory.paint);
  }

  void _swapAtlas(GlyphAtlas newAtlas) {
    final oldAtlas = _atlas;
    _atlas = newAtlas;
    notifyListeners();
    if (oldAtlas != null && !identical(oldAtlas.image, newAtlas.image)) {
      _scheduleAtlasDisposal(oldAtlas);
    }
  }

  void _scheduleAtlasDisposal(GlyphAtlas oldAtlas) {
    if (oldAtlas.isDisposed) return;
    _pendingAtlasDisposals.add(oldAtlas);
    _schedulePostFrameFlush();
  }

  void _schedulePostFrameFlush() {
    if (_postFrameDisposalScheduled || _isDisposed) return;
    _postFrameDisposalScheduled = true;
    final scheduler = SchedulerBinding.instance;
    scheduler.addPostFrameCallback((_) => _flushPendingDisposals());
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      scheduler.ensureVisualUpdate();
    }
  }

  void _flushPendingDisposals() {
    _postFrameDisposalScheduled = false;
    if (_pendingAtlasDisposals.isNotEmpty) {
      for (final atlas in _pendingAtlasDisposals.toList(growable: false)) {
        if (!atlas.isDisposed) {
          atlas.dispose();
          _disposedAtlasCount++;
        }
      }
      _pendingAtlasDisposals.clear();
    }
    if (_pendingPainterDisposals.isNotEmpty) {
      for (final painter in _pendingPainterDisposals) {
        painter.dispose();
      }
      _pendingPainterDisposals.clear();
    }
  }

  /// Clears fallback and ligature [TextPainter] caches, deferring painter disposal post-frame.
  void clearPainterCaches() {
    if (_fallbackPainters.isEmpty && _ligaturePainters.isEmpty) return;
    _pendingPainterDisposals.addAll(_fallbackPainters.values);
    _fallbackPainters.clear();
    _pendingPainterDisposals.addAll(_ligaturePainters.values);
    _ligaturePainters.clear();
    _schedulePostFrameFlush();
  }

  void _clearPainterCachesImmediate() {
    for (final painter in _fallbackPainters.values) {
      painter.dispose();
    }
    _fallbackPainters.clear();
    for (final painter in _ligaturePainters.values) {
      painter.dispose();
    }
    _ligaturePainters.clear();
    for (final painter in _pendingPainterDisposals) {
      painter.dispose();
    }
    _pendingPainterDisposals.clear();
  }

  /// Queues unbaked `(char, GlyphStyleVariant)` pairs for asynchronous atlas rasterization.
  void requestMissingStyledGlyphs(List<(String, GlyphStyleVariant)> glyphs) {
    final currentAtlas = _atlas;
    if (_isDisposed || currentAtlas == null) return;
    var needsUpdate = false;
    for (final entry in glyphs) {
      if (!_pendingGlyphs.contains(entry) &&
          !_processingGlyphs.contains(entry) &&
          !currentAtlas.styledCharRects.containsKey(entry)) {
        _pendingGlyphs.add(entry);
        needsUpdate = true;
      }
    }
    if (needsUpdate) {
      unawaited(_triggerAtlasUpdate());
    }
  }

  Future<void> _triggerAtlasUpdate() async {
    if (_isDisposed ||
        _isUpdatingAtlas ||
        _pendingGlyphs.isEmpty ||
        _atlas == null) {
      return;
    }
    _isUpdatingAtlas = true;
    final genId = _generationId;
    Tracer.record(_traceTriggerAtlasUpdateId, Phase.begin, TraceCategory.paint);

    final batch = _pendingGlyphs.toList();
    _pendingGlyphs.removeAll(batch);
    _processingGlyphs.addAll(batch);

    try {
      await Future<void>.microtask(() {});
      final baseAtlas = _atlas;
      if (_isDisposed || genId != _generationId || baseAtlas == null) return;

      final newAtlas = await baseAtlas.addStyledGlyphs(batch);
      if (_isDisposed || genId != _generationId || newAtlas.isDisposed) {
        if (!identical(baseAtlas.image, newAtlas.image)) {
          newAtlas.dispose();
        }
        return;
      }
      if (!identical(baseAtlas.image, newAtlas.image)) {
        _createdAtlasCount++;
      }
      _evictBakedFallbackPainters(batch);
      _swapAtlas(newAtlas);
    } finally {
      _processingGlyphs.removeAll(batch);
      if (genId == _generationId) {
        _isUpdatingAtlas = false;
      }
      Tracer.record(_traceTriggerAtlasUpdateId, Phase.end, TraceCategory.paint);
      if (!_isDisposed && _pendingGlyphs.isNotEmpty && genId == _generationId) {
        unawaited(_triggerAtlasUpdate());
      }
    }
  }

  void _evictBakedFallbackPainters(List<(String, GlyphStyleVariant)> baked) {
    if (_fallbackPainters.isEmpty) return;
    final bakedSet = <(String, bool, bool)>{
      for (final (char, variant) in baked)
        (char, variant.isBold, variant.isItalic),
    };
    final toRemove = <(String, bool, bool, bool, Color)>[];
    for (final key in _fallbackPainters.keys) {
      if (bakedSet.contains((key.$1, key.$2, key.$3))) {
        toRemove.add(key);
      }
    }
    for (final key in toRemove) {
      final removed = _fallbackPainters.remove(key);
      if (removed != null) {
        _pendingPainterDisposals.add(removed);
      }
    }
    if (toRemove.isNotEmpty) {
      _schedulePostFrameFlush();
    }
  }

  /// Ensures bounded fallback [TextPainter] entries exist for unbaked glyphs in [buffer].
  void ensureFallbackPaintersForBuffer(
    Buffer buffer, {
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
  }) {
    final activeAtlas = _atlas;
    if (_isDisposed || activeAtlas == null) return;

    final width = buffer.width;
    final total = width * buffer.height;
    for (var i = 0; i < total; i++) {
      final char = buffer.characters[i];
      if (char.isEmpty || char == ' ') continue;
      final x = i % width;
      final y = i ~/ width;
      final mods = buffer.getModifiers(x, y);
      if (Modifier.has(mods, Modifier.kittyPlaceholder) ||
          char.startsWith(kittyPlaceholderChar)) {
        continue;
      }
      final isBold = Modifier.has(mods, Modifier.bold);
      final isItalic = Modifier.has(mods, Modifier.italic);
      if (activeAtlas.rectFor(char, isBold: isBold, isItalic: isItalic) !=
          null) {
        continue;
      }
      _ensureSingleFallbackPainter(
        buffer,
        x: x,
        y: y,
        char: char,
        mods: mods,
        isBold: isBold,
        isItalic: isItalic,
        defaultForegroundArgb: defaultForegroundArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
        faintOpacity: faintOpacity,
        palette: palette,
      );
    }
  }

  void _ensureSingleFallbackPainter(
    Buffer buffer, {
    required int x,
    required int y,
    required String char,
    required int mods,
    required bool isBold,
    required bool isItalic,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
  }) {
    final isReverse = Modifier.has(mods, Modifier.reverse);
    final isDim = Modifier.has(mods, Modifier.dim);
    final color = Color(
      TuiAtlasPainter.resolveCellForegroundArgb(
        buffer.getForeground(x, y),
        buffer.getBackground(x, y),
        modifiers: mods,
        isReverse: isReverse,
        defaultForegroundArgb: defaultForegroundArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
        faintOpacity: faintOpacity,
        palette: palette,
      ),
    );
    final key = (char, isBold, isItalic, isDim, color);
    final existing = _fallbackPainters.remove(key);
    if (existing != null) {
      _fallbackPainters[key] = existing;
      return;
    }
    while (_fallbackPainters.length >= maxFallbackPainters) {
      final oldest = _fallbackPainters.keys.first;
      final evicted = _fallbackPainters.remove(oldest);
      if (evicted != null) {
        _pendingPainterDisposals.add(evicted);
        _schedulePostFrameFlush();
      }
    }
    _fallbackPainters[key] = TextPainter(
      text: TextSpan(
        text: char,
        style: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFamilyFallback,
          fontSize: _fontSize,
          color: color,
          fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _generationId++;
    PaintingBinding.instance.systemFonts.removeListener(
      _handleSystemFontsChange,
    );
    _clearPainterCachesImmediate();
    final current = _atlas;
    _atlas = null;
    if (current != null && !current.isDisposed) {
      current.dispose();
      _disposedAtlasCount++;
    }
    for (final pending in _pendingAtlasDisposals) {
      if (!pending.isDisposed) {
        pending.dispose();
        _disposedAtlasCount++;
      }
    }
    _pendingAtlasDisposals.clear();
    super.dispose();
  }
}
