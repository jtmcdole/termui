import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:termui_tinpot/termui_tinpot.dart';

/// Controller for communicating events (such as file drops or byte payloads) to [TinpotApp].
class TinpotAppController {
  void Function(String path)? onFileDropped;
  void Function(Uint8List bytes, String name)? onBytesDropped;
  Future<void> Function()? onPickImage;

  void setFilePath(String path) {
    onFileDropped?.call(path);
  }

  void setImageBytes(Uint8List bytes, String name) {
    onBytesDropped?.call(bytes, name);
  }

  Future<void> requestImagePick() async {
    await onPickImage?.call();
  }
}

/// Main entry point for running the Tinpot app on a given [terminal] using [SceneManager].
Future<void> runTinpotApp(
  term.Terminal terminal, {
  TinpotAppController? controller,
  String? initialImagePath,
  void Function(Buffer)? onFrameRedrawn,
}) async {
  final sceneManager = SceneManager(
    terminal,
    renderingMode: RenderingMode.alternateScreen,
  )..enableMouseTracking = true;

  final runner = PromptRunner<void>(
    terminal: terminal,
    alternateScreen: false,
    mode: ExecutionMode.managed,
    exitConditions: const {PromptExitTrigger.controlC: PromptExitAction.abort},
    widget: TinpotApp(
      controller: controller,
      initialImagePath: initialImagePath,
    ),
    onFramePainted: (buf) {
      if (onFrameRedrawn != null) onFrameRedrawn(buf);
      sceneManager.render();
    },
  );

  final mainLayer = SceneLayer(
    renderer: runner,
    sizing: LayerSizing.fullscreen,
    x: 0,
    y: 0,
    zIndex: 0,
  );

  sceneManager.layers.add(mainLayer);
  sceneManager.focusedLayer = mainLayer;

  try {
    await runner.run();
  } on PromptAbortedException catch (e) {
    if (e.trigger != PromptExitTrigger.controlC) {
      rethrow;
    }
  } finally {
    sceneManager.dispose();
  }
}

class TinpotState {
  final String status;
  final Buffer? imageBuffer;
  final bool isProcessing;
  final int width;
  final int workFactor;
  final String imagePath;
  final Map<String, int> heatmap;
  final int totalChars;

  TinpotState({
    this.status = 'Enter image path and press Convert (or drop an image)',
    this.imageBuffer,
    this.isProcessing = false,
    this.width = 80,
    this.workFactor = 9,
    this.imagePath = '',
    this.heatmap = const {},
    this.totalChars = 0,
  });

  List<MapEntry<String, int>> get topCharacters {
    final sorted = heatmap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(10).toList();
  }

  TinpotState copyWith({
    String? status,
    Buffer? imageBuffer,
    bool? isProcessing,
    int? width,
    int? workFactor,
    String? imagePath,
    Map<String, int>? heatmap,
    int? totalChars,
  }) {
    return TinpotState(
      status: status ?? this.status,
      imageBuffer: imageBuffer ?? this.imageBuffer,
      isProcessing: isProcessing ?? this.isProcessing,
      width: width ?? this.width,
      workFactor: workFactor ?? this.workFactor,
      imagePath: imagePath ?? this.imagePath,
      heatmap: heatmap ?? this.heatmap,
      totalChars: totalChars ?? this.totalChars,
    );
  }
}

class TinpotViewModel {
  TinpotState _state = TinpotState();
  final _stateController = StreamController<TinpotState>.broadcast();
  Stream<TinpotState> get stateStream => _stateController.stream;
  TinpotState get state => _state;

  img.Image? _decodedImage;
  img.Image? _scaledImage;
  final Stopwatch _stopwatch = Stopwatch();

  static final int _traceAppConvertId = Tracer.registerString(
    'TinpotApp:_convertImage',
  );
  static final int _traceAppDecodeId = Tracer.registerString(
    'TinpotApp:decodeImage',
  );

  void dispose() {
    _stateController.close();
  }

  void _emit(TinpotState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  void setWidth(int w) {
    _emit(_state.copyWith(width: w));
    if (!_state.isProcessing && _decodedImage != null) {
      _reprocess();
    }
  }

  void setWorkFactor(int wf) {
    _emit(_state.copyWith(workFactor: wf));
    if (!_state.isProcessing && _scaledImage != null) {
      _requantize();
    }
  }

  void setImagePath(String path) {
    _emit(_state.copyWith(imagePath: path));
  }

  Map<String, int> _generateHeatmap(Buffer buffer) {
    final counts = <String, int>{};
    for (int y = 0; y < buffer.height; y++) {
      for (int x = 0; x < buffer.width; x++) {
        final char = buffer.getCharacter(x, y);
        counts[char] = (counts[char] ?? 0) + 1;
      }
    }
    return counts;
  }

  Future<void> _requantize({int? decodeMs, int? scaleMs}) async {
    if (_scaledImage == null || _decodedImage == null) return;
    _emit(_state.copyWith(isProcessing: true, status: 'Re-quantizing...'));
    await Future<void>.delayed(Duration.zero);

    _stopwatch.reset();
    _stopwatch.start();

    final columns = _state.width;
    final double imageAspect = _decodedImage!.width / _decodedImage!.height;
    int rows = (columns / (imageAspect * 2.0)).round();
    if (rows < 1) rows = 1;

    final engine = TermuiTinpot(workFactor: _state.workFactor);
    final convertedBuffer = engine.quantizeScaledImage(
      _scaledImage!,
      columns,
      rows,
      useDin99d: true,
    );

    final heatmap = _generateHeatmap(convertedBuffer);
    final quantMs = _stopwatch.elapsedMilliseconds;
    _stopwatch.stop();

    String timingText = 'Quant: ${quantMs}ms';
    if (scaleMs != null) timingText = 'Scale: ${scaleMs}ms, $timingText';
    if (decodeMs != null) timingText = 'Decode: ${decodeMs}ms, $timingText';

    _emit(
      _state.copyWith(
        imageBuffer: convertedBuffer,
        heatmap: heatmap,
        totalChars: columns * rows,
        isProcessing: false,
        status: 'Success! $columns x $rows grid. ($timingText)',
      ),
    );
  }

  Future<void> _reprocess({int? decodeMs}) async {
    if (_decodedImage == null) return;
    _emit(_state.copyWith(isProcessing: true, status: 'Re-scaling...'));
    await Future<void>.delayed(Duration.zero);

    _stopwatch.reset();
    _stopwatch.start();

    final columns = _state.width;
    final double imageAspect = _decodedImage!.width / _decodedImage!.height;
    int rows = (columns / (imageAspect * 2.0)).round();
    if (rows < 1) rows = 1;

    final engine = TermuiTinpot(workFactor: _state.workFactor);
    _scaledImage = engine.scaleImage(_decodedImage!, columns, rows);
    final scaleMs = _stopwatch.elapsedMilliseconds;

    await _requantize(decodeMs: decodeMs, scaleMs: scaleMs);
  }

  Future<void> convertImageBytes(
    Uint8List imageBytes,
    String name, {
    bool internalCall = false,
  }) async {
    if (!internalCall && _state.isProcessing) return;

    Tracer.record(_traceAppConvertId, Phase.begin, TraceCategory.paint);

    _emit(
      _state.copyWith(
        isProcessing: true,
        status: 'Decoding dropped image ($name)...',
        imagePath: name,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 16));

    _stopwatch.reset();
    _stopwatch.start();
    Tracer.record(_traceAppDecodeId, Phase.begin, TraceCategory.paint);
    final image = img.decodeImage(imageBytes);
    Tracer.record(_traceAppDecodeId, Phase.end, TraceCategory.paint);
    final decodeMs = _stopwatch.elapsedMilliseconds;

    if (image == null) {
      _emit(
        _state.copyWith(
          isProcessing: false,
          status: 'Error: Failed to decode image format for $name',
        ),
      );
      Tracer.record(_traceAppConvertId, Phase.end, TraceCategory.paint);
      return;
    }

    _decodedImage = image;
    _scaledImage = null;

    await _reprocess(decodeMs: decodeMs);
    Tracer.record(_traceAppConvertId, Phase.end, TraceCategory.paint);
  }

  Future<void> convertImage() async {
    if (_state.isProcessing) return;

    final path = _state.imagePath.trim();
    if (path.isEmpty) {
      _emit(_state.copyWith(status: 'Error: Path is empty'));
      return;
    }

    final file = File(path);
    if (!await file.exists()) {
      _emit(_state.copyWith(status: 'Error: File not found ($path)'));
      return;
    }

    Tracer.record(_traceAppConvertId, Phase.begin, TraceCategory.paint);

    _emit(
      _state.copyWith(
        isProcessing: true,
        status: 'Reading image file (${file.path})...',
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 16));

    final Uint8List imageBytes;
    try {
      imageBytes = await file.readAsBytes();
    } catch (e) {
      _emit(
        _state.copyWith(isProcessing: false, status: 'Error reading file: $e'),
      );
      Tracer.record(_traceAppConvertId, Phase.end, TraceCategory.paint);
      return;
    }

    await convertImageBytes(imageBytes, file.path, internalCall: true);
  }

  Future<void> saveAscii() async {
    if (_state.isProcessing) return;

    if (_state.imageBuffer == null) {
      _emit(_state.copyWith(status: 'Error: No image converted yet.'));
      return;
    }

    _emit(_state.copyWith(status: 'Saving output.ascii...'));
    await Future<void>.delayed(const Duration(milliseconds: 16));

    const outPath = 'output.ascii';
    try {
      await File(outPath).writeAsString(_state.imageBuffer!.toAnsiString());
      _emit(_state.copyWith(status: 'Saved output to $outPath successfully.'));
    } catch (e) {
      _emit(_state.copyWith(status: 'Error saving output file: $e'));
    }
  }
}

/// The reactive termui widget for the Tinpot Image-to-ANSI Converter.
class TinpotApp extends StatefulWidget {
  final TinpotAppController? controller;
  final String? initialImagePath;

  const TinpotApp({super.key, this.controller, this.initialImagePath});

  @override
  State<TinpotApp> createState() => _TinpotAppState();
}

class _TinpotAppState extends State<TinpotApp> {
  final TextEditingController _pathController = TextEditingController();
  late final TinpotViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = TinpotViewModel();

    widget.controller?.onFileDropped = (path) {
      if (mounted && !_viewModel.state.isProcessing) {
        _pathController.text = path;
        _viewModel.setImagePath(path);
        _viewModel.convertImage();
      }
    };
    widget.controller?.onBytesDropped = (bytes, name) {
      if (mounted && !_viewModel.state.isProcessing) {
        _pathController.text = name;
        _viewModel.setImagePath(name);
        _viewModel.convertImageBytes(bytes, name);
      }
    };
    if (widget.initialImagePath != null &&
        widget.initialImagePath!.isNotEmpty) {
      _pathController.text = widget.initialImagePath!;
      _viewModel.setImagePath(widget.initialImagePath!);
      _viewModel.convertImage();
    }
  }

  @override
  void dispose() {
    widget.controller?.onFileDropped = null;
    widget.controller?.onBytesDropped = null;

    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row([
      TinpotPreview(viewModel: _viewModel),
      TinpotControlPanel(
        viewModel: _viewModel,
        controller: widget.controller,
        pathController: _pathController,
      ),
    ]);
  }
}

class TinpotPreview extends StatelessWidget {
  final TinpotViewModel viewModel;

  const TinpotPreview({super.key, required this.viewModel});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: DecoratedBox(
        decoration: const BoxDecoration(border: Border.single),
        child: StreamBuilder<TinpotState>(
          initialData: viewModel.state,
          stream: viewModel.stateStream,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            if (state.imageBuffer == null) {
              return const Center(child: Text('No image preview'));
            }
            return BufferWidget(buffer: state.imageBuffer!);
          },
        ),
      ),
    );
  }
}

class TinpotControlPanel extends StatelessWidget {
  final TinpotViewModel viewModel;
  final TinpotAppController? controller;
  final TextEditingController pathController;

  const TinpotControlPanel({
    super.key,
    required this.viewModel,
    this.controller,
    required this.pathController,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: Column([
        if (controller?.onPickImage != null)
          Row([
            Button(
              onPressed: () {
                controller?.requestImagePick();
              },
              text: 'Select Image',
            ),
          ]),
        Row([
          const Text('Path: '),
          Expanded(child: TextField(controller: pathController)),
        ]),
        const SizedBox(height: 1),
        StreamBuilder<TinpotState>(
          initialData: viewModel.state,
          stream: viewModel.stateStream,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            Color getStatusColor() {
              return switch (state) {
                _ when state.status.startsWith('Error') => const Color(
                  255,
                  100,
                  100,
                ),
                _ when state.isProcessing => const Color(0, 255, 255),
                _ when state.status.startsWith('Success') => const Color(
                  100,
                  255,
                  100,
                ),
                _ => const Color(255, 255, 0),
              };
            }

            return Column([
              Row([
                Text('Width: ${state.width} '),
                Expanded(
                  child: Slider(
                    value: state.width.toDouble(),
                    min: 10,
                    max: 200,
                    onChanged: state.isProcessing
                        ? null
                        : (v) => viewModel.setWidth(v.toInt()),
                  ),
                ),
              ]),
              Row([
                Text('Work Factor: ${state.workFactor} '),
                Expanded(
                  child: Slider(
                    value: state.workFactor.toDouble(),
                    min: 1,
                    max: 9,
                    onChanged: state.isProcessing
                        ? null
                        : (v) => viewModel.setWorkFactor(v.toInt()),
                  ),
                ),
              ]),
              const SizedBox(height: 1),
              Row([
                Button(
                  onPressed: () {
                    if (!state.isProcessing) {
                      viewModel.setImagePath(pathController.text);
                      viewModel.convertImage();
                    }
                  },
                  text: state.isProcessing ? 'Converting...' : 'Convert Image',
                ),
                const SizedBox(width: 2),
                Button(
                  onPressed: () {
                    if (!state.isProcessing) {
                      viewModel.saveAscii();
                    }
                  },
                  text: 'Save',
                ),
              ]),
              const SizedBox(height: 1),
              Text(
                'Status: ${state.status}',
                style: Style(foreground: getStatusColor()),
              ),
              const SizedBox(height: 1),
              const Text('--- Statistics ---'),
              Text('Total Characters: ${state.totalChars}'),
              Text(
                'Size: ${state.imageBuffer?.width ?? 0}x${state.imageBuffer?.height ?? 0}',
              ),
              const SizedBox(height: 1),
              const Text('Top Characters:'),
              ...state.topCharacters.map((e) => Text('"${e.key}": ${e.value}')),
            ]);
          },
        ),
      ]),
    );
  }
}
