import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:termui_tinpot/termui_tinpot.dart';

final class _TinpotComputeRequest {
  final Uint8List? encodedBytes;
  final Uint8List? decodedRgba;
  final int decodedWidth;
  final int decodedHeight;
  final Uint8List? scaledRgba;
  final int scaledWidth;
  final int scaledHeight;
  final int columns;
  final int workFactor;
  final int? priorDecodeMs;
  final int? priorScaleMs;

  const _TinpotComputeRequest({
    this.encodedBytes,
    this.decodedRgba,
    this.decodedWidth = 0,
    this.decodedHeight = 0,
    this.scaledRgba,
    this.scaledWidth = 0,
    this.scaledHeight = 0,
    required this.columns,
    required this.workFactor,
    this.priorDecodeMs,
    this.priorScaleMs,
  });
}

final class _TinpotComputeResponse {
  final bool decodeFailed;
  final Uint8List? decodedRgba;
  final int decodedWidth;
  final int decodedHeight;
  final Uint8List? scaledRgba;
  final int scaledWidth;
  final int scaledHeight;
  final int columns;
  final int rows;
  final List<String> characters;
  final Uint32List attributes;
  final Map<String, int> heatmap;
  final int? decodeMs;
  final int? scaleMs;
  final int quantMs;

  const _TinpotComputeResponse({
    this.decodeFailed = false,
    this.decodedRgba,
    this.decodedWidth = 0,
    this.decodedHeight = 0,
    this.scaledRgba,
    this.scaledWidth = 0,
    this.scaledHeight = 0,
    this.columns = 0,
    this.rows = 0,
    required this.characters,
    required this.attributes,
    required this.heatmap,
    this.decodeMs,
    this.scaleMs,
    this.quantMs = 0,
  });

  factory _TinpotComputeResponse.decodeFailure() => _TinpotComputeResponse(
    decodeFailed: true,
    characters: const [],
    attributes: Uint32List(0),
    heatmap: const {},
  );
}

_TinpotComputeResponse _runTinpotCompute(_TinpotComputeRequest req) {
  final decodedInfo = _resolveDecodedImage(req);
  if (decodedInfo == null) {
    return _TinpotComputeResponse.decodeFailure();
  }

  final (decodedImg, decodedRgba, decodedWidth, decodedHeight, decodeMs) =
      decodedInfo;
  final imageAspect = decodedWidth / decodedHeight;
  final rows = math.max(1, (req.columns / (imageAspect * 2.0)).round());

  final engine = TermuiTinpot(workFactor: req.workFactor);
  final (scaledImg, scaledRgba, scaledWidth, scaledHeight, scaleMs) =
      _resolveScaledImage(req, engine, decodedImg, rows);

  final quantWatch = Stopwatch()..start();
  final convertedBuffer = engine.quantizeScaledImage(
    scaledImg,
    req.columns,
    rows,
    useDin99d: true,
  );
  final heatmap = _computeBufferHeatmap(convertedBuffer);
  quantWatch.stop();

  return _TinpotComputeResponse(
    decodedRgba: decodedRgba,
    decodedWidth: decodedWidth,
    decodedHeight: decodedHeight,
    scaledRgba: scaledRgba,
    scaledWidth: scaledWidth,
    scaledHeight: scaledHeight,
    columns: req.columns,
    rows: rows,
    characters: convertedBuffer.characters,
    attributes: convertedBuffer.attributes,
    heatmap: heatmap,
    decodeMs: decodeMs,
    scaleMs: scaleMs,
    quantMs: quantWatch.elapsedMilliseconds,
  );
}

(img.Image?, Uint8List, int, int, int?)? _resolveDecodedImage(
  _TinpotComputeRequest req,
) {
  if (req.encodedBytes != null) {
    final sw = Stopwatch()..start();
    final image = img.decodeImage(req.encodedBytes!);
    sw.stop();
    if (image == null) return null;
    final rgba = image.getBytes(order: img.ChannelOrder.rgba);
    return (image, rgba, image.width, image.height, sw.elapsedMilliseconds);
  }

  final rgba = req.decodedRgba!;
  final image = req.scaledRgba != null
      ? null
      : _rgbaToImage(rgba, req.decodedWidth, req.decodedHeight);
  return (image, rgba, req.decodedWidth, req.decodedHeight, req.priorDecodeMs);
}

(img.Image, Uint8List, int, int, int?) _resolveScaledImage(
  _TinpotComputeRequest req,
  TermuiTinpot engine,
  img.Image? decodedImg,
  int rows,
) {
  if (req.scaledRgba != null) {
    final scaled = _rgbaToImage(
      req.scaledRgba!,
      req.scaledWidth,
      req.scaledHeight,
    );
    return (
      scaled,
      req.scaledRgba!,
      req.scaledWidth,
      req.scaledHeight,
      req.priorScaleMs,
    );
  }

  final sw = Stopwatch()..start();
  final scaled = engine.scaleImage(decodedImg!, req.columns, rows);
  sw.stop();
  final rgba = scaled.getBytes(order: img.ChannelOrder.rgba);
  return (scaled, rgba, scaled.width, scaled.height, sw.elapsedMilliseconds);
}

img.Image _rgbaToImage(Uint8List rgba, int width, int height) =>
    img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

Map<String, int> _computeBufferHeatmap(Buffer buffer) {
  final counts = <String, int>{};
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      final char = buffer.getCharacter(x, y);
      counts[char] = (counts[char] ?? 0) + 1;
    }
  }
  return counts;
}

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

  Uint8List? _decodedRgba;
  int _decodedWidth = 0;
  int _decodedHeight = 0;
  Uint8List? _scaledRgba;
  int _scaledWidth = 0;
  int _scaledHeight = 0;
  bool _isDisposed = false;

  static final int _traceAppConvertId = Tracer.registerString(
    'TinpotApp:_convertImage',
  );

  void dispose() {
    _isDisposed = true;
    _stateController.close();
  }

  void _emit(TinpotState newState) {
    if (_isDisposed) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  void setWidth(int w) {
    if (!_state.isProcessing && _decodedRgba != null) {
      _state = _state.copyWith(width: w);
      _reprocess();
    } else {
      _emit(_state.copyWith(width: w));
    }
  }

  void setWorkFactor(int wf) {
    if (!_state.isProcessing && _scaledRgba != null) {
      _state = _state.copyWith(workFactor: wf);
      _requantize();
    } else {
      _emit(_state.copyWith(workFactor: wf));
    }
  }

  void setImagePath(String path) {
    _emit(_state.copyWith(imagePath: path));
  }

  Future<void> _requantize({int? decodeMs, int? scaleMs}) async {
    if (_scaledRgba == null || _decodedRgba == null) return;
    _emit(_state.copyWith(isProcessing: true, status: 'Re-quantizing...'));

    final response = await compute(
      _runTinpotCompute,
      _TinpotComputeRequest(
        decodedRgba: _decodedRgba,
        decodedWidth: _decodedWidth,
        decodedHeight: _decodedHeight,
        scaledRgba: _scaledRgba,
        scaledWidth: _scaledWidth,
        scaledHeight: _scaledHeight,
        columns: _state.width,
        workFactor: _state.workFactor,
        priorDecodeMs: decodeMs,
        priorScaleMs: scaleMs,
      ),
    );
    _applyComputeSuccess(response);
  }

  Future<void> _reprocess({int? decodeMs}) async {
    if (_decodedRgba == null) return;
    _emit(_state.copyWith(isProcessing: true, status: 'Re-scaling...'));

    final response = await compute(
      _runTinpotCompute,
      _TinpotComputeRequest(
        decodedRgba: _decodedRgba,
        decodedWidth: _decodedWidth,
        decodedHeight: _decodedHeight,
        columns: _state.width,
        workFactor: _state.workFactor,
        priorDecodeMs: decodeMs,
      ),
    );
    _applyComputeSuccess(response);
  }

  void _applyComputeSuccess(_TinpotComputeResponse response) {
    if (_isDisposed) return;

    _decodedRgba = response.decodedRgba;
    _decodedWidth = response.decodedWidth;
    _decodedHeight = response.decodedHeight;
    _scaledRgba = response.scaledRgba;
    _scaledWidth = response.scaledWidth;
    _scaledHeight = response.scaledHeight;

    final convertedBuffer = Buffer.blank(response.columns, response.rows);
    convertedBuffer.characters.setAll(0, response.characters);
    convertedBuffer.attributes.setAll(0, response.attributes);

    final timingText = _formatTimings(
      decodeMs: response.decodeMs,
      scaleMs: response.scaleMs,
      quantMs: response.quantMs,
    );

    _emit(
      _state.copyWith(
        imageBuffer: convertedBuffer,
        heatmap: response.heatmap,
        totalChars: response.columns * response.rows,
        isProcessing: false,
        status:
            'Success! ${response.columns} x ${response.rows} grid. ($timingText)',
      ),
    );
  }

  static String _formatTimings({
    int? decodeMs,
    int? scaleMs,
    required int quantMs,
  }) {
    final parts = <String>[
      if (decodeMs != null) 'Decode: ${decodeMs}ms',
      if (scaleMs != null) 'Scale: ${scaleMs}ms',
      'Quant: ${quantMs}ms',
    ];
    return parts.join(', ');
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

    final response = await compute(
      _runTinpotCompute,
      _TinpotComputeRequest(
        encodedBytes: imageBytes,
        columns: _state.width,
        workFactor: _state.workFactor,
      ),
    );

    if (response.decodeFailed) {
      _emit(
        _state.copyWith(
          isProcessing: false,
          status: 'Error: Failed to decode image format for $name',
        ),
      );
      Tracer.record(_traceAppConvertId, Phase.end, TraceCategory.paint);
      return;
    }

    _applyComputeSuccess(response);
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

  static Color _statusColor(TinpotState state) {
    if (state.status.startsWith('Error')) return const Color(255, 100, 100);
    if (state.isProcessing) return const Color(0, 255, 255);
    if (state.status.startsWith('Success')) return const Color(100, 255, 100);
    return const Color(255, 255, 0);
  }

  Widget _buildStateSection(TinpotState state) {
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
      _buildActionButtons(state),
      const SizedBox(height: 1),
      Text(
        'Status: ${state.status}',
        style: Style(foreground: _statusColor(state)),
      ),
      const SizedBox(height: 1),
      const Text('--- Statistics ---'),
      Text('Total Characters: ${state.totalChars}'),
      Text(
        'Size: ${state.imageBuffer?.width ?? 0}x${state.imageBuffer?.height ?? 0}',
      ),
      const SizedBox(height: 1),
      const Text('Top Characters:'),
      for (final MapEntry(:key, :value) in state.topCharacters)
        Text('"$key": $value'),
    ]);
  }

  Widget _buildActionButtons(TinpotState state) {
    return Row([
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
    ]);
  }

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
          builder: (context, snapshot) => _buildStateSection(snapshot.data!),
        ),
      ]),
    );
  }
}
