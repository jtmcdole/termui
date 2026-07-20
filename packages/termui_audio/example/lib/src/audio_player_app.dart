// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:math' as math;
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:termui_audio/termui_audio.dart';

typedef AssetLoader =
    Future<AudioBuffer> Function(
      String assetPath, {
      LoadProgressCallback? onProgress,
    });

const Map<String, String> playlist = {
  'Clouds': 'assets/DontFallOffTheClouds.ogg',
  'Swish 1': 'assets/fast_swish1.ogg',
  'Swish 2': 'assets/fast_swish2.ogg',
  'Swish 3': 'assets/fast_swish3.ogg',
  'Swish 4': 'assets/fast_swish4.ogg',
};

Future<void> runAudioPlayerApp(
  term.Terminal terminal,
  TermuiAudioEngine audioService,
  AssetLoader loadAsset, {
  bool isFlutter = false,
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
    widget: AudioPlayerAppWidget(
      terminal: terminal,
      audioService: audioService,
      loadAsset: loadAsset,
    ),
    onFramePainted: (buf) {
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

class AudioPlayerAppWidget extends StatefulWidget {
  final term.Terminal terminal;
  final TermuiAudioEngine audioService;
  final AssetLoader loadAsset;

  const AudioPlayerAppWidget({
    super.key,
    required this.terminal,
    required this.audioService,
    required this.loadAsset,
  });

  @override
  State<AudioPlayerAppWidget> createState() => _AudioPlayerAppWidgetState();
}

class _AudioPlayerAppWidgetState extends State<AudioPlayerAppWidget> {
  bool isLoading = true;
  double loadProgress = 0.0;
  bool _startedLoading = false;

  late final List<AudioBuffer?> loadedSounds = List.filled(
    playlist.length,
    null,
  );
  late final List<String> names = playlist.keys.toList();
  late final List<String> paths = playlist.values.toList();

  final List<double> sourceX = [0.0, -5.0, 5.0, -5.0, 5.0];
  final List<double> sourceY = [0.0, -5.0, -5.0, 5.0, 5.0];
  final List<AudioVoice?> activeVoices = List.filled(5, null);

  double bgmVolume = 1.0;
  double sfxVolume = 1.0;

  @override
  void initState() {
    super.initState();
    if (!_startedLoading) {
      _startedLoading = true;
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    for (int i = 0; i < paths.length; i++) {
      final b = await widget.loadAsset(
        paths[i],
        onProgress: (p) {
          if (mounted) {
            setState(() {
              loadProgress = (i + p) / paths.length;
            });
          }
        },
      );
      loadedSounds[i] = b;
    }
    if (mounted) {
      setState(() {
        isLoading = false;
        loadProgress = 1.0;
      });
    }
  }

  void _togglePlay(int index) {
    if (activeVoices[index] != null) {
      widget.audioService.stop(activeVoices[index]!);
      activeVoices[index] = null;
    } else {
      activeVoices[index] = widget.audioService.play3d(
        loadedSounds[index]!,
        sourceX[index],
        sourceY[index],
        0.0,
      );
      // Apply initial volume
      final vol = index == 0 ? bgmVolume : sfxVolume;
      widget.audioService.setVoiceVolume(activeVoices[index]!, vol);
    }
    setState(() {});
  }

  void _setBgmVolume(double value) {
    setState(() => bgmVolume = value);
    if (activeVoices[0] != null) {
      widget.audioService.setVoiceVolume(activeVoices[0]!, value);
    }
  }

  void _setSfxVolume(double value) {
    setState(() => sfxVolume = value);
    for (int i = 1; i < activeVoices.length; i++) {
      if (activeVoices[i] != null) {
        widget.audioService.setVoiceVolume(activeVoices[i]!, value);
      }
    }
  }

  void _updatePos(int index, double nx, double ny) {
    setState(() {
      sourceX[index] = nx;
      sourceY[index] = ny;
    });
    if (activeVoices[index] != null) {
      widget.audioService.set3dSourceParameters(
        activeVoices[index]!,
        sourceX[index],
        sourceY[index],
        0.0,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Align(
        alignment: Alignment.center,
        child: Column([
          const Text('Loading Audio Assets...'),
          const SizedBox(height: 1),
          LinearProgressIndicator(loadProgress, showPercentage: true),
        ]),
      );
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (event) {
        if (event.type == KeyType.character && event.key.toLowerCase() == 'q') {
          PromptScope.of(context)?.done();
          return true;
        }
        return false;
      },
      child: Align(
        alignment: Alignment.center,
        child: Column([
          const Text(
            '=== 3D SPATIAL AUDIO GRID ===',
            style: Style(
              foreground: CharmColors.julep,
              modifiers: Modifier.bold,
            ),
          ),
          const SizedBox(height: 1),
          const Text('Click and drag the numbers 1-5 to move sound sources.'),
          const Text('The listener is positioned at the blue "X" (center).'),
          const Text(
            'Press Q to quit.',
            style: Style(foreground: Colors.white),
          ),
          const SizedBox(height: 1),
          Row([
            for (int i = 0; i < names.length; i++) ...[
              InkwellButton(
                text: activeVoices[i] != null ? '>> ${names[i]}' : names[i],
                onPressed: () => _togglePlay(i),
                color1: CharmColors.charple,
                color2: CharmColors.hazy,
              ),
              const SizedBox(width: 1),
            ],
          ]),
          const SizedBox(height: 1),
          Row([
            const Text('BGM Volume: '),
            SizedBox(
              width: 20,
              height: 1,
              child: Slider(
                value: bgmVolume,
                min: 0.0,
                max: 1.0,
                onChanged: _setBgmVolume,
              ),
            ),
            const SizedBox(width: 4),
            const Text('SFX Volume: '),
            SizedBox(
              width: 20,
              height: 1,
              child: Slider(
                value: sfxVolume,
                min: 0.0,
                max: 1.0,
                onChanged: _setSfxVolume,
              ),
            ),
          ]),
          const SizedBox(height: 1),
          SpatialGridArea(
            width: 50,
            height: 15,
            sourceX: sourceX,
            sourceY: sourceY,
            onPositionChanged: _updatePos,
          ),
        ]),
      ),
    );
  }
}

class SpatialGridArea extends Widget {
  final int width;
  final int height;
  final List<double> sourceX;
  final List<double> sourceY;
  final void Function(int, double, double) onPositionChanged;

  const SpatialGridArea({
    required this.width,
    required this.height,
    required this.sourceX,
    required this.sourceY,
    required this.onPositionChanged,
  });

  @override
  int getIntrinsicWidth(int height) => width;

  @override
  int getIntrinsicHeight(int width) => height;

  @override
  Element createElement() => SpatialGridAreaElement(this);
}

class SpatialGridAreaElement extends LeafElement implements MouseEventHandler {
  SpatialGridAreaElement(SpatialGridArea super.widget);

  @override
  SpatialGridArea get widget => super.widget as SpatialGridArea;

  bool _isDragging = false;
  int? _draggingIndex;

  @override
  void handleMouseEvent(term.MouseEvent event, int localX, int localY) {
    if (event.type == term.MouseEventType.press) {
      _draggingIndex = _findClosest(localX, localY);
      if (_draggingIndex != null) {
        _isDragging = true;
        _updatePos(localX, localY);
      }
    } else if (event.type == term.MouseEventType.drag &&
        _isDragging &&
        _draggingIndex != null) {
      _updatePos(localX, localY);
    } else if (event.type == term.MouseEventType.release) {
      _isDragging = false;
      _draggingIndex = null;
    }
  }

  int? _findClosest(int localX, int localY) {
    double minDistance = double.infinity;
    int? closest;
    for (int i = 0; i < widget.sourceX.length; i++) {
      final sx = ((widget.sourceX[i] + 10.0) / 20.0 * (widget.width - 1))
          .round()
          .clamp(0, widget.width - 1);
      final sy = ((widget.sourceY[i] + 10.0) / 20.0 * (widget.height - 1))
          .round()
          .clamp(0, widget.height - 1);

      final dist = math.sqrt(
        math.pow(sx - localX, 2) + math.pow(sy - localY, 2),
      );
      if (dist < 3.0 && dist < minDistance) {
        minDistance = dist;
        closest = i;
      }
    }
    return closest;
  }

  void _updatePos(int lx, int ly) {
    if (_draggingIndex == null) return;
    final clampX = lx.clamp(0, widget.width - 1);
    final clampY = ly.clamp(0, widget.height - 1);

    // Map grid coordinates to physical space: -10.0 to +10.0
    final nx =
        (clampX / (widget.width > 1 ? widget.width - 1 : 1)) * 20.0 - 10.0;
    final ny =
        (clampY / (widget.height > 1 ? widget.height - 1 : 1)) * 20.0 - 10.0;
    widget.onPositionChanged(_draggingIndex!, nx, ny);
    markNeedsBuild();
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    // Fill grid dots
    for (int y = 0; y < widget.height; y++) {
      for (int x = 0; x < widget.width; x++) {
        buffer.writeString(
          offset.dx + x,
          offset.dy + y,
          '.',
          const Style(foreground: Colors.white),
        );
      }
    }

    // Draw listener at center
    final cx = widget.width ~/ 2;
    final cy = widget.height ~/ 2;
    buffer.writeString(
      offset.dx + cx,
      offset.dy + cy,
      'X',
      const Style(foreground: Colors.blue),
    );

    // Draw audio sources
    for (int i = 0; i < widget.sourceX.length; i++) {
      final sx = ((widget.sourceX[i] + 10.0) / 20.0 * (widget.width - 1))
          .round()
          .clamp(0, widget.width - 1);
      final sy = ((widget.sourceY[i] + 10.0) / 20.0 * (widget.height - 1))
          .round()
          .clamp(0, widget.height - 1);
      buffer.writeString(
        offset.dx + sx,
        offset.dy + sy,
        '${i + 1}',
        const Style(foreground: Colors.green),
      );
    }
  }
}
