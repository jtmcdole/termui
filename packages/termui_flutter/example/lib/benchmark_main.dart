import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/perf/fs_locator.dart';
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
  drawRawAtlasSingle(
    'drawRawAtlas (Background only)',
    'One atlas draw call for background blocks.',
  ),
  drawRawAtlasDouble(
    'drawRawAtlas (Bg + Fg)',
    'Two atlas draw calls (bg + fg characters) - Realistic TUI mode.',
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
  const RenderMode(this.name, this.description);
}

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  RenderMode _currentMode = RenderMode.drawRawAtlasDouble;

  // Terminal Dimensions
  final int _cols = 449;
  final int _rows = 81;

  // Measurement Stats
  double _cpuPaintTimeMs = 0.0;
  double _fps = 0.0;
  int _frameCount = 0;
  int _lastFpsTimestamp = 0;

  bool _isRecordingTrace = false;
  String _traceFilePath = '';

  ui.Image? _whitePixelAtlas;
  ui.Image? _glyphAtlas;

  @override
  void initState() {
    super.initState();
    Tracer.initialize();

    // Create benchmark assets
    _setupAtlases().then((_) {
      _lastFpsTimestamp = DateTime.now().millisecondsSinceEpoch;
      _ticker = createTicker((_) {
        if (mounted) {
          setState(() {
            _frameCount++;
            final now = DateTime.now().millisecondsSinceEpoch;
            final elapsed = now - _lastFpsTimestamp;
            if (elapsed >= 500) {
              _fps = (_frameCount * 1000.0) / elapsed;
              _frameCount = 0;
              _lastFpsTimestamp = now;
            }
          });
        }
      })..start();
    });
  }

  Future<void> _setupAtlases() async {
    // 1. Create a 16x16 white pixel atlas for background coloring
    final recorderBg = ui.PictureRecorder();
    final canvasBg = Canvas(recorderBg);
    canvasBg.drawRect(
      const Rect.fromLTWH(0, 0, 16, 16),
      Paint()..color = Colors.white,
    );
    final pictureBg = recorderBg.endRecording();
    _whitePixelAtlas = await pictureBg.toImage(16, 16);

    // 2. Create a simulated font glyph atlas (grid of letters)
    final recorderFg = ui.PictureRecorder();
    final canvasFg = Canvas(recorderFg);

    // Draw 16x16 characters onto a 256x256 image
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
      }
    }
    final pictureFg = recorderFg.endRecording();
    _glyphAtlas = await pictureFg.toImage(256, 256);
  }

  @override
  void dispose() {
    _ticker.dispose();
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
      final timestamp = DateTime.now().millisecondsSinceEpoch;
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
    final timestamp = DateTime.now().millisecondsSinceEpoch;
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

    // Run for 200 frames (approx 3.3 seconds at 60fps)
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
    if (_whitePixelAtlas == null || _glyphAtlas == null) {
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

    final totalCells = _cols * _rows;

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
          // Control Panel
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF1E1E24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
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
                            '${_cols}x$_rows cells ($totalCells total)',
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
                          Row(
                            children: [
                              Text(
                                '${_fps.toStringAsFixed(1)} FPS',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _fps > 55
                                      ? Colors.green
                                      : (_fps > 30
                                            ? Colors.orange
                                            : Colors.red),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Text(
                                '${_cpuPaintTimeMs.toStringAsFixed(3)} ms CPU',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _cpuPaintTimeMs < 1.0
                                      ? Colors.green
                                      : (_cpuPaintTimeMs < 8.0
                                            ? Colors.orange
                                            : Colors.red),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
                  children: [
                    for (final mode in RenderMode.values)
                      ChoiceChip(
                        label: Text(mode.name),
                        selected: _currentMode == mode,
                        selectedColor: Theme.of(context).colorScheme.primary,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _currentMode = mode;
                              _frameCount = 0;
                              _lastFpsTimestamp =
                                  DateTime.now().millisecondsSinceEpoch;
                            });
                          }
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
                const SizedBox(height: 16),
                Row(
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.flash_on),
                      label: const Text('Run Automated 200-Frame Benchmark'),
                      onPressed: _isRecordingTrace
                          ? null
                          : _runAutomatedBenchmark,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.secondary,
                        foregroundColor: Colors.black,
                      ),
                    ),
                    if (_isRecordingTrace) ...[
                      const SizedBox(width: 16),
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.red,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Recording trace: ${getDefaultFileSystem().path.basename(_traceFilePath)}',
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // Interactive Terminal Grid Canvas Area
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: const Color(0xFF2E2E38)),
                borderRadius: BorderRadius.circular(4),
              ),
              clipBehavior: Clip.hardEdge,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: GridBenchmarkPainter(
                      mode: _currentMode,
                      whitePixelAtlas: _whitePixelAtlas!,
                      glyphAtlas: _glyphAtlas!,
                      cols: _cols,
                      rows: _rows,
                      onMeasure: (ms) {
                        // Avoid setState here to prevent re-triggering painter build.
                        // We update the state variable directly. Ticker will read it on next tick.
                        _cpuPaintTimeMs = ms;
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GridBenchmarkPainter extends CustomPainter {
  final RenderMode mode;
  final ui.Image whitePixelAtlas;
  final ui.Image glyphAtlas;
  final int cols;
  final int rows;
  final Function(double) onMeasure;

  // Pre-allocated arrays for zero-GC drawRawAtlas
  late final Float32List transformsBg;
  late final Float32List rectsBg;
  late final Int32List colorsBg;

  late final Float32List transformsFg;
  late final Float32List rectsFg;
  late final Int32List colorsFg;

  // Tracing string IDs
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

    // Background arrays
    transformsBg = Float32List(count * 4);
    rectsBg = Float32List(count * 4);
    colorsBg = Int32List(count);

    // Foreground arrays
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
      final Float32List transformsSub = Float32List.sublistView(
        transforms,
        i * 4,
        end * 4,
      );
      final Float32List rectsSub = Float32List.sublistView(
        rects,
        i * 4,
        end * 4,
      );
      final Int32List colorsSub = Int32List.sublistView(colors, i, end);

      canvas.drawRawAtlas(
        image,
        transformsSub,
        rectsSub,
        colorsSub,
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
        dev.Timeline.startSync('Prepare Buffers');
        Tracer.record(_tracePrepId, Phase.begin, TraceCategory.paint);
        // Prepare background block colors and transforms
        for (var i = 0; i < count; i++) {
          final col = i % cols;
          final row = i ~/ cols;
          final x = col * cellWidth;
          final y = row * cellHeight;

          // Scale 16x16 white square to cell size
          transformsBg[i * 4 + 0] = cellWidth / 16.0;
          transformsBg[i * 4 + 1] = 0.0;
          transformsBg[i * 4 + 2] = x;
          transformsBg[i * 4 + 3] = y;

          rectsBg[i * 4 + 0] = 0.0;
          rectsBg[i * 4 + 1] = 0.0;
          rectsBg[i * 4 + 2] = 16.0;
          rectsBg[i * 4 + 3] = 16.0;

          // Color tint: Alternate blue and red
          colorsBg[i] = ((col + row) % 2 == 0) ? 0xFF3F51B5 : 0xFFE91E63;
        }
        Tracer.record(_tracePrepId, Phase.end, TraceCategory.paint);
        dev.Timeline.finishSync();

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
        dev.Timeline.finishSync();
        break;

      case RenderMode.drawRawAtlasDouble:
        dev.Timeline.startSync('Prepare Buffers');
        Tracer.record(_tracePrepId, Phase.begin, TraceCategory.paint);
        // 1. Prepare Background & Foreground buffers
        for (var i = 0; i < count; i++) {
          final col = i % cols;
          final row = i ~/ cols;
          final x = col * cellWidth;
          final y = row * cellHeight;

          // Scale 16x16 white square to cell size for background
          transformsBg[i * 4 + 0] = cellWidth / 16.0;
          transformsBg[i * 4 + 1] = 0.0;
          transformsBg[i * 4 + 2] = x;
          transformsBg[i * 4 + 3] = y;

          rectsBg[i * 4 + 0] = 0.0;
          rectsBg[i * 4 + 1] = 0.0;
          rectsBg[i * 4 + 2] = 16.0;
          rectsBg[i * 4 + 3] = 16.0;

          colorsBg[i] = ((col + row) % 2 == 0) ? 0xFF121214 : 0xFF1A1A1E;

          // Choose a simulated glyph index from the 16x16 glyph grid (256x256 atlas)
          final glyphIndex = (col + row) % 256;
          final srcX = (glyphIndex % 16) * 16.0;
          final srcY = (glyphIndex ~/ 16) * 16.0;

          // Foreground (Character text atlas)
          final fgScale = cellWidth / 16.0;
          transformsFg[i * 4 + 0] = fgScale;
          transformsFg[i * 4 + 1] = 0.0;
          transformsFg[i * 4 + 2] = x - fgScale * srcX;
          transformsFg[i * 4 + 3] = y - fgScale * srcY;

          rectsFg[i * 4 + 0] = srcX;
          rectsFg[i * 4 + 1] = srcY;
          rectsFg[i * 4 + 2] = srcX + 16.0;
          rectsFg[i * 4 + 3] = srcY + 16.0;

          // Foreground color tint: Alternate green, yellow, cyan
          colorsFg[i] = (col % 3 == 0)
              ? 0xFF00FF00
              : (col % 3 == 1 ? 0xFFFFEB3B : 0xFF00E5FF);
        }
        Tracer.record(_tracePrepId, Phase.end, TraceCategory.paint);
        dev.Timeline.finishSync();

        // Draw backgrounds
        _drawRawAtlasInChunks(
          canvas,
          whitePixelAtlas,
          transformsBg,
          rectsBg,
          colorsBg,
          count,
          BlendMode.modulate,
          Paint(),
        );

        // Draw foreground glyphs on top
        _drawRawAtlasInChunks(
          canvas,
          glyphAtlas,
          transformsFg,
          rectsFg,
          colorsFg,
          count,
          BlendMode.modulate,
          Paint(),
        );
        Tracer.record(_traceDrawId, Phase.end, TraceCategory.paint);
        dev.Timeline.finishSync();
        break;

      case RenderMode.drawRectLoop:
        dev.Timeline.startSync('Canvas DrawRect Loop');
        Tracer.record(_traceDrawId, Phase.begin, TraceCategory.paint);
        final bgPaint = Paint();
        // Benchmark standard drawRect calls
        for (var row = 0; row < rows; row++) {
          for (var col = 0; col < cols; col++) {
            final rect = Rect.fromLTWH(
              col * cellWidth,
              row * cellHeight,
              cellWidth,
              cellHeight,
            );
            bgPaint.color = ((col + row) % 2 == 0)
                ? const Color(0xFF3F51B5)
                : const Color(0xFFE91E63);
            canvas.drawRect(rect, bgPaint);
          }
        }
        Tracer.record(_traceDrawId, Phase.end, TraceCategory.paint);
        dev.Timeline.finishSync();
        break;

      case RenderMode.textPainterLoop:
        dev.Timeline.startSync('Canvas TextPainter Loop');
        Tracer.record(_traceDrawId, Phase.begin, TraceCategory.paint);
        final bgPaint = Paint();

        // Note: Creating TextPainters in the paint loop is bad practice, but we do it to demonstrate the baseline standard approach's impact.
        for (var row = 0; row < rows; row++) {
          for (var col = 0; col < cols; col++) {
            final rect = Rect.fromLTWH(
              col * cellWidth,
              row * cellHeight,
              cellWidth,
              cellHeight,
            );

            // Background
            bgPaint.color = ((col + row) % 2 == 0)
                ? const Color(0xFF121214)
                : const Color(0xFF1A1A1E);
            canvas.drawRect(rect, bgPaint);

            // Foreground Text
            final char = String.fromCharCode(65 + (col + row) % 26);
            final tp = TextPainter(
              text: TextSpan(
                text: char,
                style: TextStyle(
                  fontSize: cellHeight * 0.8,
                  color: Colors.green,
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: cellWidth);

            tp.paint(canvas, Offset(col * cellWidth, row * cellHeight));
          }
        }
        Tracer.record(_traceDrawId, Phase.end, TraceCategory.paint);
        dev.Timeline.finishSync();
        break;
    }

    sw.stop();
    onMeasure(sw.elapsedMicroseconds / 1000.0);
    Tracer.record(_tracePaintId, Phase.end, TraceCategory.paint);
    dev.Timeline.finishSync();
  }

  @override
  bool shouldRepaint(covariant GridBenchmarkPainter oldDelegate) => true;
}
