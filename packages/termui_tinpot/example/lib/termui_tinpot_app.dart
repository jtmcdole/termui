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

  void setFilePath(String path) {
    onFileDropped?.call(path);
  }

  void setImageBytes(Uint8List bytes, String name) {
    onBytesDropped?.call(bytes, name);
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

  TinpotState({
    this.status = 'Enter image path and press Convert (or drop an image)',
    this.imageBuffer,
    this.isProcessing = false,
    this.width = 80,
    this.workFactor = 9,
    this.imagePath = '',
  });

  TinpotState copyWith({
    String? status,
    Buffer? imageBuffer,
    bool? isProcessing,
    int? width,
    int? workFactor,
    String? imagePath,
  }) {
    return TinpotState(
      status: status ?? this.status,
      imageBuffer: imageBuffer ?? this.imageBuffer,
      isProcessing: isProcessing ?? this.isProcessing,
      width: width ?? this.width,
      workFactor: workFactor ?? this.workFactor,
      imagePath: imagePath ?? this.imagePath,
    );
  }
}

class TinpotViewModel {
  TinpotState _state = TinpotState();
  final _stateController = StreamController<TinpotState>.broadcast();
  Stream<TinpotState> get stateStream => _stateController.stream;
  TinpotState get state => _state;

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
  }

  void setWorkFactor(int wf) {
    _emit(_state.copyWith(workFactor: wf));
  }

  void setImagePath(String path) {
    _emit(_state.copyWith(imagePath: path));
  }

  Future<void> convertImageBytes(Uint8List imageBytes, String name) async {
    if (_state.isProcessing) return;

    Tracer.record(_traceAppConvertId, Phase.begin, TraceCategory.paint);

    _emit(
      _state.copyWith(
        isProcessing: true,
        status: 'Decoding dropped image ($name)...',
        imagePath: name,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 16));

    Tracer.record(_traceAppDecodeId, Phase.begin, TraceCategory.paint);
    final image = img.decodeImage(imageBytes);
    Tracer.record(_traceAppDecodeId, Phase.end, TraceCategory.paint);

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

    final double imageAspect = image.width / image.height;
    int columns = _state.width;
    int rows = (columns / (imageAspect * 2.0)).round();

    if (columns < 1) columns = 1;
    if (rows < 1) rows = 1;

    _emit(
      _state.copyWith(
        status:
            'Converting ${image.width}x${image.height} image to $columns x $rows ANSI grid...',
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 16));

    final engine = TermuiTinpot(workFactor: _state.workFactor);
    final convertedBuffer = engine.convertBuffer(
      image,
      columns,
      rows,
      useDin99d: true,
    );

    Tracer.record(_traceAppConvertId, Phase.end, TraceCategory.paint);

    _emit(
      _state.copyWith(
        imageBuffer: convertedBuffer,
        isProcessing: false,
        status:
            'Success! Converted $name (${image.width}x${image.height}) to $columns x $rows grid. Press Save to export.',
      ),
    );
  }

  Future<void> convertImage() async {
    if (_state.isProcessing) return;

    final path = _state.imagePath.trim();
    if (path.isEmpty) {
      _emit(_state.copyWith(status: 'Error: Path is empty'));
      return;
    }

    final file = File(path);
    if (!file.existsSync()) {
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

    await convertImageBytes(imageBytes, file.path);
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
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column([
      Column([
        Row([
          const Text('Image Path: '),
          Expanded(child: TextField(controller: _pathController)),
        ]),
        const SizedBox(height: 1),
        StreamBuilder<TinpotState>(
          initialData: _viewModel.state,
          stream: _viewModel.stateStream,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            return Row([
              Text('Width: ${state.width} '),
              Expanded(
                child: Slider(
                  value: state.width.toDouble(),
                  min: 10,
                  max: 200,
                  onChanged: state.isProcessing
                      ? null
                      : (v) => _viewModel.setWidth(v.toInt()),
                ),
              ),
            ]);
          },
        ),
        StreamBuilder<TinpotState>(
          initialData: _viewModel.state,
          stream: _viewModel.stateStream,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            return Row([
              Text('Work Factor: ${state.workFactor} '),
              Expanded(
                child: Slider(
                  value: state.workFactor.toDouble(),
                  min: 1,
                  max: 9,
                  onChanged: state.isProcessing
                      ? null
                      : (v) => _viewModel.setWorkFactor(v.toInt()),
                ),
              ),
            ]);
          },
        ),
        const SizedBox(height: 1),
        StreamBuilder<TinpotState>(
          initialData: _viewModel.state,
          stream: _viewModel.stateStream,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            return Row([
              Button(
                onPressed: () {
                  if (!state.isProcessing) {
                    _viewModel.setImagePath(_pathController.text);
                    _viewModel.convertImage();
                  }
                },
                text: state.isProcessing ? 'Converting...' : 'Convert Image',
              ),
              const SizedBox(width: 2),
              Button(
                onPressed: () {
                  if (!state.isProcessing) {
                    _viewModel.saveAscii();
                  }
                },
                text: 'Save .ascii',
              ),
            ]);
          },
        ),
        const SizedBox(height: 1),
        StreamBuilder<TinpotState>(
          initialData: _viewModel.state,
          stream: _viewModel.stateStream,
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

            return Text(
              'Status: ${state.status}',
              style: Style(foreground: getStatusColor()),
            );
          },
        ),
      ]),
      Expanded(
        child: DecoratedBox(
          decoration: const BoxDecoration(border: Border.single),
          child: StreamBuilder<TinpotState>(
            initialData: _viewModel.state,
            stream: _viewModel.stateStream,
            builder: (context, snapshot) {
              final state = snapshot.data!;
              if (state.isProcessing) {
                return const Center(
                  child: Text(
                    '⌛ Working... Reading file and converting image grid',
                    style: Style(foreground: Color(0, 255, 255)),
                  ),
                );
              }
              if (state.imageBuffer == null) {
                return const Center(child: Text('No image preview'));
              }
              return BufferWidget(buffer: state.imageBuffer!);
            },
          ),
        ),
      ),
    ]);
  }
}
