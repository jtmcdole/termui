import 'dart:async';
import 'dart:developer' as dev;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/perf/fs_locator.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/termui.dart' as tui;
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  runApp(const BenchmarkApp());
}

class BenchmarkApp extends StatelessWidget {
  const BenchmarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermUI Rendering Benchmark',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121214),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6200EE),
          secondary: Color(0xFF03DAC6),
          surface: Color(0xFF1E1E24),
        ),
      ),
      home: const BenchmarkScreen(),
    );
  }
}

enum RenderMode {
  tuiTailLog200x60(
    'TuiAtlasPainter 200x60 (1-row tail log)',
    'Mutates 1 tail row per frame on a 200x60 Buffer with TuiAtlasStagingCache.',
    isTuiMode: true,
  ),
  tuiCursorBlink200x60(
    'TuiAtlasPainter 200x60 (cursor blink)',
    'Toggles 1 interior cursor cell per frame on a 200x60 Buffer (row compaction).',
    isTuiMode: true,
  ),
  tuiCurlyDiagnostics200x60(
    'TuiAtlasPainter 200x60 (curly underlines)',
    'Dense SGR 4:3 curly, dotted, and dashed underlines via pre-baked atlas sprites (0 Paths).',
    isTuiMode: true,
  ),
  tuiCjkNerdRedraw200x60(
    'TuiAtlasPainter 200x60 (CJK/NerdFont redraw)',
    'Full 200x60 dirty redraw with wide CJK glyphs, Nerd Font icons, and box drawing.',
    isTuiMode: true,
  ),
  drawRawAtlasSingle(
    'drawRawAtlas (Background only)',
    'One atlas draw call for background blocks.',
  ),
  drawRawAtlasDouble(
    'drawRawAtlas (Bg + Fg)',
    'Two atlas draw calls (bg + fg characters) - Synthetic baseline.',
  ),
  drawRectLoop(
    'canvas.drawRect Loop',
    'Iterates cell-by-cell and calls canvas.drawRect. (Tessellation test)',
  ),
  textPainterLoop(
    'TextPainter Loop (Heavy)',
    'Iterates cell-by-cell and paints a TextPainter. (Layout & Font test)',
  );

  final String name;
  final String description;
  final bool isTuiMode;

  const RenderMode(this.name, this.description, {this.isTuiMode = false});
}

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen>
    with SingleTickerProviderStateMixin {
  static const int _tuiCols = 200;
  static const int _tuiRows = 60;
  static const int _legacyCols = 449;
  static const int _legacyRows = 81;

  Ticker? _ticker;
  RenderMode _currentMode = RenderMode.tuiTailLog200x60;
  bool _enableRowCache = true;

  // Measurement stats
  double _cpuPaintTimeMs = 0.0;
  double _fps = 0.0;
  int _lastRowHits = 0;
  int _lastRowMisses = 0;
  int _frameCount = 0;
  int _tickIndex = 0;
  int _lastFpsTimestamp = 0;

  bool _isRecordingTrace = false;
  String _traceFilePath = '';

  ui.Image? _whitePixelAtlas;
  ui.Image? _glyphAtlas;
  GlyphAtlas? _tuiAtlas;
  final TuiAtlasStagingCache _stagingCache = TuiAtlasStagingCache();
  final tui.Buffer _tuiBuffer = tui.Buffer.blank(_tuiCols, _tuiRows);
  final Map<(String, bool, bool, bool, Color), TextPainter> _fallbackPainters =
      {};

  int get _activeCols => _currentMode.isTuiMode ? _tuiCols : _legacyCols;
  int get _activeRows => _currentMode.isTuiMode ? _tuiRows : _legacyRows;

  @override
  void initState() {
    super.initState();
    Tracer.initialize();

    _setupAtlases().then((_) {
      if (!mounted) return;
      _seedTuiBufferForMode(_currentMode);
      _lastFpsTimestamp = clock.now().millisecondsSinceEpoch;
      _ticker = createTicker(_onTick)..start();
      setState(() {});
    });
  }

  void _onTick(Duration _) {
    if (!mounted) return;
    _tickIndex++;
    if (_currentMode.isTuiMode) {
      _mutateTuiBufferForTick(_currentMode, _tickIndex);
    }
    setState(() {
      _frameCount++;
      final now = clock.now().millisecondsSinceEpoch;
      final elapsed = now - _lastFpsTimestamp;
      if (elapsed >= 500) {
        _fps = (_frameCount * 1000.0) / elapsed;
        _frameCount = 0;
        _lastFpsTimestamp = now;
      }
    });
  }

  Future<void> _setupAtlases() async {
    final recorderBg = ui.PictureRecorder();
    final canvasBg = Canvas(recorderBg);
    canvasBg.drawRect(
      const Rect.fromLTWH(0, 0, 16, 16),
      Paint()..color = Colors.white,
    );
    final pictureBg = recorderBg.endRecording();
    _whitePixelAtlas = await pictureBg.toImage(16, 16);
    pictureBg.dispose();

    final recorderFg = ui.PictureRecorder();
    final canvasFg = Canvas(recorderFg);
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        final char = String.fromCharCode(32 + (y * 16 + x) % 95);
        final tp = TextPainter(
          text: TextSpan(
            text: char,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white,
              fontFamily: 'Cascadia Mono',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvasFg, Offset(x * 16.0 + 2, y * 16.0 + 1));
        tp.dispose();
      }
    }
    final pictureFg = recorderFg.endRecording();
    _glyphAtlas = await pictureFg.toImage(256, 256);
    pictureFg.dispose();

    final baseAtlas = await GlyphAtlasGenerator.generate(
      fontSize: 13.0,
      fontFamily: 'Cascadia Mono',
      fontFamilyFallback: const ['MesloLGS NF'],
    );
    final expanded = await baseAtlas.addGlyphs(const [
      '漢',
      '字',
      '中',
      '文',
      '終',
      '端',
      '\uE0B0',
      '\uE0B2',
      '\uF07C',
      '\uE798',
      '🚀',
    ]);
    if (!identical(expanded.image, baseAtlas.image)) {
      baseAtlas.dispose();
    }
    _tuiAtlas = expanded;
  }

  void _seedTuiBufferForMode(RenderMode mode) {
    _tuiBuffer.clear();
    _stagingCache.invalidateAllRows();
    switch (mode) {
      case RenderMode.tuiTailLog200x60:
        _seedLogRows(_tuiBuffer);
      case RenderMode.tuiCursorBlink200x60:
        _seedLogRows(_tuiBuffer);
      case RenderMode.tuiCurlyDiagnostics200x60:
        _seedCurlyDiagnosticRows(_tuiBuffer);
      case RenderMode.tuiCjkNerdRedraw200x60:
        _seedCjkNerdRows(_tuiBuffer, frame: 0);
      case RenderMode.drawRawAtlasSingle ||
          RenderMode.drawRawAtlasDouble ||
          RenderMode.drawRectLoop ||
          RenderMode.textPainterLoop:
        break;
    }
  }

  void _mutateTuiBufferForTick(RenderMode mode, int tick) {
    switch (mode) {
      case RenderMode.tuiTailLog200x60:
        _writeTailLogRow(_tuiBuffer, _tuiRows - 1, tick);
      case RenderMode.tuiCursorBlink200x60:
        final idx = (30 * _tuiCols + 42) * 3 + 2;
        final mods = _tuiBuffer.attributes[idx];
        _tuiBuffer.attributes[idx] = tick.isEven
            ? (mods | tui.Modifier.reverse)
            : (mods & ~tui.Modifier.reverse);
      case RenderMode.tuiCurlyDiagnostics200x60:
        _writeCurlyDiagnosticRow(_tuiBuffer, tick % _tuiRows, tick);
      case RenderMode.tuiCjkNerdRedraw200x60:
        _seedCjkNerdRows(_tuiBuffer, frame: tick);
      case RenderMode.drawRawAtlasSingle ||
          RenderMode.drawRawAtlasDouble ||
          RenderMode.drawRectLoop ||
          RenderMode.textPainterLoop:
        break;
    }
  }

  static void _seedLogRows(tui.Buffer buf) {
    for (var y = 0; y < buf.height; y++) {
      _writeTailLogRow(buf, y, y);
    }
  }

  static void _writeTailLogRow(tui.Buffer buf, int row, int seq) {
    final line =
        '[INFO ${seq.toString().padLeft(6, '0')}] '
        'worker=atlas-stage row=$row status=OK '
        'throughput=${(120 + (seq % 40))}fps delta=${seq % 99}us '
        'payload=0123456789abcdef_0123456789abcdef_0123456789abcdef';
    final fg = (seq % 3 == 0)
        ? const tui.Color(0x62, 0xD1, 0x96)
        : (seq % 3 == 1
              ? const tui.Color(0xE6, 0xED, 0xF3)
              : const tui.Color(0x79, 0xB8, 0xFF));
    final bg = row.isEven
        ? const tui.Color(0x14, 0x17, 0x1F)
        : const tui.Color(0x1A, 0x1E, 0x28);
    final style = tui.Style(foreground: fg, background: bg);
    buf.writeString(0, row, line.padRight(buf.width), style);
  }

  static void _seedCurlyDiagnosticRows(tui.Buffer buf) {
    for (var y = 0; y < buf.height; y++) {
      _writeCurlyDiagnosticRow(buf, y, y);
    }
  }

  static void _writeCurlyDiagnosticRow(tui.Buffer buf, int row, int seq) {
    final ulStyle = switch ((row + seq) % 3) {
      0 => tui.UnderlineStyle.curly,
      1 => tui.UnderlineStyle.dashed,
      _ => tui.UnderlineStyle.dotted,
    };
    final ulColor = switch ((row + seq) % 3) {
      0 => const tui.Color(0xFF, 0x55, 0x55),
      1 => const tui.Color(0xFF, 0xD8, 0x66),
      _ => const tui.Color(0x56, 0xB6, 0xC2),
    };
    final text =
        'diag[$row:${seq % 999}] unused_symbol_under_curl_check -> '
        'expected TuiAtlasStagingCache match at col ${(seq * 7) % 120}';
    buf.writeString(
      0,
      row,
      text.padRight(buf.width),
      tui.Style(
        foreground: const tui.Color(0xE6, 0xED, 0xF3),
        underlineStyle: ulStyle,
        underlineColor: ulColor,
      ),
    );
  }

  static void _seedCjkNerdRows(tui.Buffer buf, {required int frame}) {
    const glyphs = ['漢', '字', '中', '文', '終', '端'];
    const icons = ['\uE0B0', '\uF07C', '\uE798', '│', '─'];
    final accentFg = frame.isEven
        ? const tui.Color(0x79, 0xB8, 0xFF)
        : const tui.Color(0xA6, 0xE3, 0xA1);
    final styleA = tui.Style(foreground: accentFg);
    final styleB = const tui.Style(
      foreground: tui.Color(0xE5, 0xC0, 0x7B),
      modifiers: tui.Modifier.bold,
    );
    for (var y = 0; y < buf.height; y++) {
      var x = 0;
      while (x + 5 < buf.width) {
        final idx = (x + y + frame) % glyphs.length;
        buf.writeString(x, y, icons[(x + y) % icons.length], styleB);
        buf.writeString(x + 1, y, glyphs[idx], styleA);
        buf.writeString(x + 3, y, 'ok', styleA);
        x += 5;
      }
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _whitePixelAtlas?.dispose();
    _glyphAtlas?.dispose();
    _tuiAtlas?.dispose();
    for (final tp in _fallbackPainters.values) {
      tp.dispose();
    }
    super.dispose();
  }

  Future<void> _toggleTrace() async {
    if (_isRecordingTrace) {
      final path = _traceFilePath;
      await Tracer.stop();
      if (path.isNotEmpty) {
        final fs = getDefaultFileSystem();
        final file = fs.file(path);
        if (file.existsSync()) {
          final bytes = file.readAsBytesSync();
          await saveFile(fs.path.basename(path), bytes);
        }
      }
      if (mounted) {
        setState(() {
          _isRecordingTrace = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Benchmark trace saved to: $_traceFilePath'),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(label: 'Dismiss', onPressed: () {}),
          ),
        );
      }
    } else {
      final fs = getDefaultFileSystem();
      final timestamp = clock.now().millisecondsSinceEpoch;
      final path = fs.path.join(
        fs.currentDirectory.path,
        'benchmark_trace_$timestamp.json.gz',
      );
      await Tracer.start(path, fs: fs);
      if (mounted) {
        setState(() {
          _isRecordingTrace = true;
          _traceFilePath = path;
        });
      }
    }
  }

  Future<void> _runAutomatedBenchmark() async {
    if (_isRecordingTrace) return;

    final fs = getDefaultFileSystem();
    final timestamp = clock.now().millisecondsSinceEpoch;
    final path = fs.path.join(
      fs.currentDirectory.path,
      'auto_benchmark_trace_$timestamp.json.gz',
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Starting 200-frame automated benchmark...'),
      ),
    );

    await Tracer.start(path, fs: fs);
    setState(() {
      _isRecordingTrace = true;
      _traceFilePath = path;
    });

    var framesRemaining = 200;
    Timer.periodic(const Duration(milliseconds: 16), (timer) async {
      if (framesRemaining <= 0) {
        timer.cancel();
        await Tracer.stop();
        final file = fs.file(path);
        if (file.existsSync()) {
          final bytes = file.readAsBytesSync();
          await saveFile(fs.path.basename(path), bytes);
        }
        if (mounted) {
          setState(() {
            _isRecordingTrace = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Benchmark trace saved to: $path'),
              duration: const Duration(seconds: 8),
              action: SnackBarAction(label: 'Dismiss', onPressed: () {}),
            ),
          );
        }
      }
      framesRemaining--;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_whitePixelAtlas == null || _glyphAtlas == null || _tuiAtlas == null) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Generating Texture Atlases...',
                style: TextStyle(fontSize: 18),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('TermUI Rendering Engine Benchmark'),
        backgroundColor: const Color(0xFF1E1E24),
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              _isRecordingTrace ? Icons.stop_circle : Icons.fiber_manual_record,
              color: _isRecordingTrace ? Colors.red : Colors.green,
            ),
            tooltip: _isRecordingTrace
                ? 'Stop Recording Trace'
                : 'Start Recording Trace',
            onPressed: _toggleTrace,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildControlPanel(context),
          Expanded(child: _buildCanvasArea()),
        ],
      ),
    );
  }

  Widget _buildControlPanel(BuildContext context) {
    final cols = _activeCols;
    final rows = _activeRows;
    final totalCells = cols * rows;
    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF1E1E24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildStatsRow(cols, rows, totalCells),
          const SizedBox(height: 16),
          const Text(
            'RENDERING MODE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final mode in RenderMode.values)
                ChoiceChip(
                  label: Text(mode.name),
                  selected: _currentMode == mode,
                  selectedColor: Theme.of(context).colorScheme.primary,
                  onSelected: (selected) {
                    if (!selected) return;
                    setState(() {
                      _currentMode = mode;
                      _frameCount = 0;
                      _lastFpsTimestamp = clock.now().millisecondsSinceEpoch;
                      if (mode.isTuiMode) {
                        _seedTuiBufferForMode(mode);
                      }
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _currentMode.description,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.grey,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 12),
          _buildActionsRow(context),
        ],
      ),
    );
  }

  Widget _buildStatsRow(int cols, int rows, int totalCells) {
    final fpsColor = _fps > 55
        ? Colors.green
        : (_fps > 30 ? Colors.orange : Colors.red);
    final cpuColor = _cpuPaintTimeMs < 0.4
        ? Colors.green
        : (_cpuPaintTimeMs < 2.0 ? Colors.orange : Colors.red);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'GRID RESOLUTION',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${cols}x$rows cells ($totalCells total)',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PERFORMANCE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 16,
                children: [
                  Text(
                    '${_fps.toStringAsFixed(1)} FPS',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: fpsColor,
                    ),
                  ),
                  Text(
                    '${_cpuPaintTimeMs.toStringAsFixed(3)} ms CPU',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: cpuColor,
                    ),
                  ),
                  if (_currentMode.isTuiMode)
                    Text(
                      'Rows: $_lastRowHits hit / $_lastRowMisses miss',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.cyanAccent,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActionsRow(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ElevatedButton.icon(
          icon: const Icon(Icons.flash_on),
          label: const Text('Run Automated 200-Frame Benchmark'),
          onPressed: _isRecordingTrace ? null : _runAutomatedBenchmark,
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.secondary,
            foregroundColor: Colors.black,
          ),
        ),
        if (_currentMode.isTuiMode)
          FilterChip(
            label: Text('Row Cache: ${_enableRowCache ? "ON" : "OFF"}'),
            selected: _enableRowCache,
            onSelected: (value) {
              setState(() {
                _enableRowCache = value;
                _stagingCache.invalidateAllRows();
              });
            },
          ),
        if (_isRecordingTrace) ...[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red),
          ),
          Text(
            'Recording trace: ${getDefaultFileSystem().path.basename(_traceFilePath)}',
            style: const TextStyle(
              color: Colors.red,
              fontSize: 12,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCanvasArea() {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: const Color(0xFF2E2E38)),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          if (_currentMode.isTuiMode) {
            return CustomPaint(
              size: size,
              painter: _TuiAtlasBenchmarkPainter(
                mode: _currentMode,
                buffer: _tuiBuffer,
                atlas: _tuiAtlas!,
                stagingCache: _enableRowCache ? _stagingCache : null,
                fallbackPainters: _fallbackPainters,
                onMeasure: (ms, hits, misses) {
                  _cpuPaintTimeMs = ms;
                  _lastRowHits = hits;
                  _lastRowMisses = misses;
                },
              ),
            );
          }
          return CustomPaint(
            size: size,
            painter: GridBenchmarkPainter(
              mode: _currentMode,
              whitePixelAtlas: _whitePixelAtlas!,
              glyphAtlas: _glyphAtlas!,
              cols: _legacyCols,
              rows: _legacyRows,
              onMeasure: (ms) {
                _cpuPaintTimeMs = ms;
              },
            ),
          );
        },
      ),
    );
  }
}

final class _TuiAtlasBenchmarkPainter extends CustomPainter {
  static final int _traceTuiPaintId = Tracer.registerString(
    'TuiAtlasPainter:benchmark_paint',
  );

  final RenderMode mode;
  final tui.Buffer buffer;
  final GlyphAtlas atlas;
  final TuiAtlasStagingCache? stagingCache;
  final Map<(String, bool, bool, bool, Color), TextPainter> fallbackPainters;
  final void Function(double ms, int hits, int misses) onMeasure;

  const _TuiAtlasBenchmarkPainter({
    required this.mode,
    required this.buffer,
    required this.atlas,
    required this.stagingCache,
    required this.fallbackPainters,
    required this.onMeasure,
  });

  @override
  void paint(Canvas canvas, Size size) {
    dev.Timeline.startSync('TuiAtlasBenchmarkPainter.${mode.name}');
    Tracer.record(_traceTuiPaintId, Phase.begin, TraceCategory.paint);
    final sw = Stopwatch()..start();
    try {
      final painter = TuiAtlasPainter(
        buffer: buffer,
        atlas: atlas,
        stagingCache: stagingCache,
        fontFamily: 'Cascadia Mono',
        fontFamilyFallback: const ['MesloLGS NF'],
        fallbackPainters: fallbackPainters,
        onMissingGlyphs: null,
        defaultBackgroundArgb: 0xFF14171F,
        defaultForegroundArgb: 0xFFE6EDF3,
      );
      painter.paint(canvas, size);
    } finally {
      sw.stop();
      Tracer.record(_traceTuiPaintId, Phase.end, TraceCategory.paint);
      dev.Timeline.finishSync();
    }
    onMeasure(
      sw.elapsedMicroseconds / 1000.0,
      stagingCache?.lastRowHits ?? 0,
      stagingCache?.lastRowMisses ?? buffer.height,
    );
  }

  @override
  bool shouldRepaint(covariant _TuiAtlasBenchmarkPainter oldDelegate) => true;
}

class GridBenchmarkPainter extends CustomPainter {
  final RenderMode mode;
  final ui.Image whitePixelAtlas;
  final ui.Image glyphAtlas;
  final int cols;
  final int rows;
  final void Function(double) onMeasure;

  late final Float32List transformsBg;
  late final Float32List rectsBg;
  late final Int32List colorsBg;

  late final Float32List transformsFg;
  late final Float32List rectsFg;
  late final Int32List colorsFg;

  static final int _tracePaintId = Tracer.registerString('paint');
  static final int _tracePrepId = Tracer.registerString('prepare_buffers');
  static final int _traceDrawId = Tracer.registerString('canvas_draw_calls');

  GridBenchmarkPainter({
    required this.mode,
    required this.whitePixelAtlas,
    required this.glyphAtlas,
    required this.cols,
    required this.rows,
    required this.onMeasure,
  }) {
    final count = cols * rows;
    transformsBg = Float32List(count * 4);
    rectsBg = Float32List(count * 4);
    colorsBg = Int32List(count);
    transformsFg = Float32List(count * 4);
    rectsFg = Float32List(count * 4);
    colorsFg = Int32List(count);
  }

  void _drawRawAtlasInChunks(
    Canvas canvas,
    ui.Image image,
    Float32List transforms,
    Float32List rects,
    Int32List colors,
    int totalSprites,
    BlendMode blendMode,
    Paint paint,
  ) {
    const int chunkSize = 500;
    for (int i = 0; i < totalSprites; i += chunkSize) {
      final int end = (i + chunkSize < totalSprites)
          ? i + chunkSize
          : totalSprites;
      canvas.drawRawAtlas(
        image,
        Float32List.sublistView(transforms, i * 4, end * 4),
        Float32List.sublistView(rects, i * 4, end * 4),
        Int32List.sublistView(colors, i, end),
        blendMode,
        null,
        paint,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    dev.Timeline.startSync('GridBenchmarkPainter.paint');
    Tracer.record(_tracePaintId, Phase.begin, TraceCategory.paint);

    final sw = Stopwatch()..start();
    final cellWidth = size.width / cols;
    final cellHeight = size.height / rows;
    final count = cols * rows;

    switch (mode) {
      case RenderMode.drawRawAtlasSingle:
        _paintAtlasSingle(canvas, cellWidth, cellHeight, count);
      case RenderMode.drawRawAtlasDouble:
        _paintAtlasDouble(canvas, cellWidth, cellHeight, count);
      case RenderMode.drawRectLoop:
        _paintDrawRectLoop(canvas, cellWidth, cellHeight);
      case RenderMode.textPainterLoop:
        _paintTextPainterLoop(canvas, cellWidth, cellHeight);
      case RenderMode.tuiTailLog200x60 ||
          RenderMode.tuiCursorBlink200x60 ||
          RenderMode.tuiCurlyDiagnostics200x60 ||
          RenderMode.tuiCjkNerdRedraw200x60:
        break;
    }

    sw.stop();
    onMeasure(sw.elapsedMicroseconds / 1000.0);
    Tracer.record(_tracePaintId, Phase.end, TraceCategory.paint);
    dev.Timeline.finishSync();
  }

  void _paintAtlasSingle(
    Canvas canvas,
    double cellWidth,
    double cellHeight,
    int count,
  ) {
    Tracer.record(_tracePrepId, Phase.begin, TraceCategory.paint);
    for (var i = 0; i < count; i++) {
      final col = i % cols;
      final row = i ~/ cols;
      final base = i * 4;
      transformsBg[base] = cellWidth / 16.0;
      transformsBg[base + 1] = 0.0;
      transformsBg[base + 2] = col * cellWidth;
      transformsBg[base + 3] = row * cellHeight;
      rectsBg[base] = 0.0;
      rectsBg[base + 1] = 0.0;
      rectsBg[base + 2] = 16.0;
      rectsBg[base + 3] = 16.0;
      colorsBg[i] = ((col + row) % 2 == 0) ? 0xFF3F51B5 : 0xFFE91E63;
    }
    Tracer.record(_tracePrepId, Phase.end, TraceCategory.paint);
    Tracer.record(_traceDrawId, Phase.begin, TraceCategory.paint);
    _drawRawAtlasInChunks(
      canvas,
      whitePixelAtlas,
      transformsBg,
      rectsBg,
      colorsBg,
      count,
      BlendMode.srcIn,
      Paint(),
    );
    Tracer.record(_traceDrawId, Phase.end, TraceCategory.paint);
  }

  void _paintAtlasDouble(
    Canvas canvas,
    double cellWidth,
    double cellHeight,
    int count,
  ) {
    Tracer.record(_tracePrepId, Phase.begin, TraceCategory.paint);
    final fgScale = cellWidth / 16.0;
    for (var i = 0; i < count; i++) {
      final col = i % cols;
      final row = i ~/ cols;
      final x = col * cellWidth;
      final y = row * cellHeight;
      final base = i * 4;
      transformsBg[base] = fgScale;
      transformsBg[base + 1] = 0.0;
      transformsBg[base + 2] = x;
      transformsBg[base + 3] = y;
      rectsBg[base] = 0.0;
      rectsBg[base + 1] = 0.0;
      rectsBg[base + 2] = 16.0;
      rectsBg[base + 3] = 16.0;
      colorsBg[i] = ((col + row) % 2 == 0) ? 0xFF121214 : 0xFF1A1A1E;

      final glyphIndex = (col + row) % 256;
      final srcX = (glyphIndex % 16) * 16.0;
      final srcY = (glyphIndex ~/ 16) * 16.0;
      transformsFg[base] = fgScale;
      transformsFg[base + 1] = 0.0;
      transformsFg[base + 2] = x - fgScale * srcX;
      transformsFg[base + 3] = y - fgScale * srcY;
      rectsFg[base] = srcX;
      rectsFg[base + 1] = srcY;
      rectsFg[base + 2] = srcX + 16.0;
      rectsFg[base + 3] = srcY + 16.0;
      colorsFg[i] = (col % 3 == 0)
          ? 0xFF00FF00
          : (col % 3 == 1 ? 0xFFFFEB3B : 0xFF00E5FF);
    }
    Tracer.record(_tracePrepId, Phase.end, TraceCategory.paint);
    Tracer.record(_traceDrawId, Phase.begin, TraceCategory.paint);
    final paint = Paint();
    _drawRawAtlasInChunks(
      canvas,
      whitePixelAtlas,
      transformsBg,
      rectsBg,
      colorsBg,
      count,
      BlendMode.modulate,
      paint,
    );
    _drawRawAtlasInChunks(
      canvas,
      glyphAtlas,
      transformsFg,
      rectsFg,
      colorsFg,
      count,
      BlendMode.modulate,
      paint,
    );
    Tracer.record(_traceDrawId, Phase.end, TraceCategory.paint);
  }

  void _paintDrawRectLoop(Canvas canvas, double cellWidth, double cellHeight) {
    Tracer.record(_traceDrawId, Phase.begin, TraceCategory.paint);
    final bgPaint = Paint();
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        bgPaint.color = ((col + row) % 2 == 0)
            ? const Color(0xFF3F51B5)
            : const Color(0xFFE91E63);
        canvas.drawRect(
          Rect.fromLTWH(
            col * cellWidth,
            row * cellHeight,
            cellWidth,
            cellHeight,
          ),
          bgPaint,
        );
      }
    }
    Tracer.record(_traceDrawId, Phase.end, TraceCategory.paint);
  }

  void _paintTextPainterLoop(
    Canvas canvas,
    double cellWidth,
    double cellHeight,
  ) {
    Tracer.record(_traceDrawId, Phase.begin, TraceCategory.paint);
    final bgPaint = Paint();
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        bgPaint.color = ((col + row) % 2 == 0)
            ? const Color(0xFF121214)
            : const Color(0xFF1A1A1E);
        canvas.drawRect(
          Rect.fromLTWH(
            col * cellWidth,
            row * cellHeight,
            cellWidth,
            cellHeight,
          ),
          bgPaint,
        );
        final tp = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(65 + (col + row) % 26),
            style: TextStyle(fontSize: cellHeight * 0.8, color: Colors.green),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: cellWidth);
        tp.paint(canvas, Offset(col * cellWidth, row * cellHeight));
        tp.dispose();
      }
    }
    Tracer.record(_traceDrawId, Phase.end, TraceCategory.paint);
  }

  @override
  bool shouldRepaint(covariant GridBenchmarkPainter oldDelegate) => true;
}
