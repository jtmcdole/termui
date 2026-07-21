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

class AudioPlayerViewModel {
  final TermuiAudioEngine audioService;
  final AssetLoader _loadAsset;

  bool isLoading = true;
  double loadProgress = 0.0;
  String? loadError;
  bool _startedLoading = false;

  final List<AudioBuffer?> loadedSounds = List.filled(playlist.length, null);
  final List<String> names = playlist.keys.toList();
  final List<String> paths = playlist.values.toList();

  final List<double> sourceX = [0.0, -5.0, 5.0, -5.0, 5.0];
  final List<double> sourceY = [0.0, -5.0, -5.0, 5.0, 5.0];
  final List<AudioVoice?> activeVoices = List.filled(5, null);

  double bgmVolume = 1.0;
  double sfxVolume = 1.0;
  int activeRadarIndex = 0;

  Duration currentBgmPosition = Duration.zero;
  Duration bgmDuration = Duration.zero;

  final List<void Function()> _listeners = [];

  AudioPlayerViewModel({
    required this.audioService,
    required AssetLoader loadAsset,
  }) : _loadAsset = loadAsset;

  void dispose() {}

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

  Future<void> loadAll() async {
    if (_startedLoading) return;
    _startedLoading = true;

    try {
      for (int i = 0; i < paths.length; i++) {
        final b = await _loadAsset(
          paths[i],
          onProgress: (p) {
            loadProgress = (i + p) / paths.length;
            _notifyListeners();
          },
        );
        loadedSounds[i] = b;
      }
      isLoading = false;
      loadProgress = 1.0;
      _notifyListeners();
    } catch (e, stack) {
      loadError = '$e\n$stack';
      _notifyListeners();
    }
  }

  void togglePlay(int index) {
    if (activeVoices[index] != null) {
      audioService.stop(activeVoices[index]!);
      activeVoices[index] = null;
      if (index == 0) {
        currentBgmPosition = Duration.zero;
      }
    } else {
      final voice = audioService.play3d(
        loadedSounds[index]!,
        sourceX[index],
        sourceY[index],
        0.0,
      );

      // Enable distance attenuation so the sound fades out as it moves away
      audioService.set3dSourceMinMaxDistance(voice, 2.0, 20.0);
      audioService.set3dSourceAttenuation(
        voice,
        AttenuationModel.linearDistance,
        1.0,
      );

      activeVoices[index] = voice;
      voice.completed.then((_) {
        if (activeVoices[index] == voice) {
          activeVoices[index] = null;
          if (index == 0) {
            currentBgmPosition = Duration.zero;
          }
          _notifyListeners();
        }
      });
      final vol = index == 0 ? bgmVolume : sfxVolume;
      audioService.setVoiceVolume(activeVoices[index]!, vol);

      if (index == 0) {
        bgmDuration = audioService.getBufferDuration(loadedSounds[index]!);
      }
    }
    _notifyListeners();
  }

  void setBgmVolume(double value) {
    bgmVolume = math.min(1.0, math.max(0.0, value));
    if (activeVoices[0] != null) {
      audioService.setVoiceVolume(activeVoices[0]!, bgmVolume);
    }
    _notifyListeners();
  }

  void changeBgmVolume(double delta) => setBgmVolume(bgmVolume + delta);

  void setSfxVolume(double value) {
    sfxVolume = math.min(1.0, math.max(0.0, value));
    for (int i = 1; i < activeVoices.length; i++) {
      if (activeVoices[i] != null) {
        audioService.setVoiceVolume(activeVoices[i]!, sfxVolume);
      }
    }
    _notifyListeners();
  }

  void changeSfxVolume(double delta) => setSfxVolume(sfxVolume + delta);

  void setRadarIndex(int index) {
    activeRadarIndex = index % names.length;
    _notifyListeners();
  }

  void cycleRadarIndex() {
    activeRadarIndex = (activeRadarIndex + 1) % names.length;
    _notifyListeners();
  }

  void updatePos(int index, double nx, double ny) {
    sourceX[index] = nx;
    sourceY[index] = ny;
    if (activeVoices[index] != null) {
      audioService.set3dSourceParameters(
        activeVoices[index]!,
        sourceX[index],
        sourceY[index],
        0.0,
      );
    }
    _notifyListeners();
  }

  void seekBgm(double progress) {
    if (activeVoices[0] != null && bgmDuration.inMilliseconds > 0) {
      final position = Duration(
        milliseconds: (progress * bgmDuration.inMilliseconds).round(),
      );
      audioService.seek(activeVoices[0]!, position);
      currentBgmPosition = position;
      _notifyListeners();
    }
  }

  void moveRadarIndex(double dx, double dy) {
    updatePos(
      activeRadarIndex,
      sourceX[activeRadarIndex] + dx,
      sourceY[activeRadarIndex] + dy,
    );
  }
}

Future<void> runAudioPlayerApp(
  term.Terminal terminal,
  TermuiAudioEngine audioService,
  AssetLoader loadAsset, {
  bool isFlutter = false,
  void Function(Buffer)? onFrameRedrawn,
}) async {
  final sceneManager = SceneManager(
    terminal,
    renderingMode: RenderingMode.alternateScreen,
  )..enableMouseTracking = true;

  final viewModel = AudioPlayerViewModel(
    audioService: audioService,
    loadAsset: loadAsset,
  );

  // Decoupled loading: Start loading in the background before or during UI rendering.
  viewModel.loadAll();

  final runner = PromptRunner<void>(
    terminal: terminal,
    alternateScreen: false,
    mode: ExecutionMode.managed,
    exitConditions: const {PromptExitTrigger.controlC: PromptExitAction.abort},
    widget: AudioPlayerAppWidget(viewModel: viewModel),
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

class AudioPlayerAppWidget extends StatefulWidget {
  final AudioPlayerViewModel viewModel;

  const AudioPlayerAppWidget({super.key, required this.viewModel});

  @override
  State<AudioPlayerAppWidget> createState() => _AudioPlayerAppWidgetState();
}

class _AudioPlayerAppWidgetState extends State<AudioPlayerAppWidget> {
  late final List<FocusNode> _buttonNodes;

  void _onStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _buttonNodes = List.generate(5, (i) => FocusNode(id: 'audio_btn_$i'));
    widget.viewModel.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    for (final node in _buttonNodes) {
      node.dispose();
    }
    widget.viewModel.removeListener(_onStateChanged);
    widget.viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;

    if (vm.loadError != null) {
      return Align(
        alignment: Alignment.center,
        child: Text(
          'Error loading audio: ${vm.loadError}',
          style: const Style(foreground: Colors.red),
        ),
      );
    }

    if (vm.isLoading) {
      return Align(
        alignment: Alignment.center,
        child: Column([
          const Text('Loading Audio Assets...'),
          const SizedBox(height: 1),
          LinearProgressIndicator(vm.loadProgress, showPercentage: true),
        ]),
      );
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (event) {
        switch (event.type) {
          case KeyType.tab:
          case KeyType.left:
          case KeyType.right:
            int focusedIndex = _buttonNodes.indexWhere((n) => n.hasFocus);
            if (focusedIndex == -1) focusedIndex = 0;
            final nextIndex = event.type == KeyType.left
                ? (focusedIndex - 1 + _buttonNodes.length) % _buttonNodes.length
                : (focusedIndex + 1) % _buttonNodes.length;
            _buttonNodes[nextIndex].requestFocus();
            return true;
          case KeyType.character:
            switch (event.key.toLowerCase()) {
              case 'q':
                PromptScope.of(context)?.done();
                return true;
              case 'w':
                vm.moveRadarIndex(0, -1.0);
                return true;
              case 's':
                vm.moveRadarIndex(0, 1.0);
                return true;
              case 'a':
                vm.moveRadarIndex(-1.0, 0);
                return true;
              case 'd':
                vm.moveRadarIndex(1.0, 0);
                return true;
              case '=' || '+':
                vm.changeBgmVolume(0.05);
                return true;
              case '-' || '_':
                vm.changeBgmVolume(-0.05);
                return true;
              case ']':
                vm.changeSfxVolume(0.05);
                return true;
              case '[':
                vm.changeSfxVolume(-0.05);
                return true;
              case '1' || '2' || '3' || '4' || '5':
                vm.togglePlay(int.parse(event.key.toLowerCase()) - 1);
                return true;
              default:
                break;
            }
          default:
            break;
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
            'Q: Quit | 1-5 / Space: Play | Tab / Arrow Keys: Select Button',
            style: Style(foreground: Colors.white),
          ),
          const Text(
            'WASD: Move Grid Focus',
            style: Style(foreground: Colors.white),
          ),
          const Text(
            '-/+: BGM Volume | [/]: SFX Volume',
            style: Style(foreground: Colors.white),
          ),
          const SizedBox(height: 1),
          Row([
            for (final (i, name) in vm.names.indexed) ...[
              InkwellButton(
                focusNode: _buttonNodes[i],
                text: vm.activeVoices[i] != null ? '>> $name' : name,
                onPressed: () => vm.togglePlay(i),
                onFocusChange: (focused) {
                  if (focused) vm.setRadarIndex(i);
                },
                color1: CharmColors.charple,
                color2: CharmColors.hazy,
              ),
              const SizedBox(width: 2),
            ],
          ]),
          const SizedBox(height: 1),
          Row([
            const Text('BGM Volume: '),
            SizedBox(
              width: 20,
              height: 1,
              child: Slider(
                value: vm.bgmVolume,
                min: 0.0,
                max: 1.0,
                onChanged: vm.setBgmVolume,
              ),
            ),
            const SizedBox(width: 4),
            const Text('SFX Volume: '),
            SizedBox(
              width: 20,
              height: 1,
              child: Slider(
                value: vm.sfxVolume,
                min: 0.0,
                max: 1.0,
                onChanged: vm.setSfxVolume,
              ),
            ),
          ]),
          const SizedBox(height: 1),
          Row([
            const Text('BGM Progress: '),
            BgmProgressSliderWidget(viewModel: vm),
          ]),
          const SizedBox(height: 1),
          SpatialGridArea(
            width: 50,
            height: 15,
            sourceX: vm.sourceX,
            sourceY: vm.sourceY,
            activeIndex: vm.activeRadarIndex,
            onPositionChanged: vm.updatePos,
          ),
        ]),
      ),
    );
  }
}

class BgmProgressSliderWidget extends StatefulWidget {
  final AudioPlayerViewModel viewModel;
  const BgmProgressSliderWidget({super.key, required this.viewModel});

  @override
  State<BgmProgressSliderWidget> createState() =>
      _BgmProgressSliderWidgetState();
}

class _BgmProgressSliderWidgetState extends State<BgmProgressSliderWidget> {
  Timer? _positionTicker;
  Duration _currentPosition = Duration.zero;

  @override
  void initState() {
    super.initState();
    _positionTicker = Timer.periodic(TuiAnimationConfig.vsyncInterval, (_) {
      final voice = widget.viewModel.activeVoices[0];
      if (voice != null) {
        final pos = widget.viewModel.audioService.getVoicePosition(voice);
        if (pos != _currentPosition && mounted) {
          setState(() {
            _currentPosition = pos;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _positionTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;
    final durationMs = vm.bgmDuration.inMilliseconds;
    return SizedBox(
      width: 45,
      height: 1,
      child: Slider(
        value: durationMs > 0
            ? _currentPosition.inMilliseconds / durationMs
            : 0.0,
        min: 0.0,
        max: 1.0,
        onChanged: (val) {
          vm.seekBgm(val);
          setState(() {
            _currentPosition = Duration(
              milliseconds: (val * durationMs).round(),
            );
          });
        },
      ),
    );
  }
}

class SpatialGridArea extends Widget {
  final int width;
  final int height;
  final List<double> sourceX;
  final List<double> sourceY;
  final int activeIndex;
  final void Function(int, double, double) onPositionChanged;

  const SpatialGridArea({
    required this.width,
    required this.height,
    required this.sourceX,
    required this.sourceY,
    required this.activeIndex,
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
      final isActive = i == widget.activeIndex;
      buffer.writeString(
        offset.dx + sx,
        offset.dy + sy,
        '${i + 1}',
        Style(
          foreground: isActive ? Colors.yellow : Colors.green,
          modifiers: isActive
              ? Modifier.bold | Modifier.reverse
              : Modifier.none,
        ),
      );
    }
  }
}
