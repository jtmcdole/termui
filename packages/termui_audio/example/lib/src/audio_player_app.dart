// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:termui_audio/termui_audio.dart';

typedef AssetLoader = Future<SoundHandle> Function(String assetPath);

const Map<String, String> playlist = {
  'Clouds': 'assets/DontFallOffTheClouds.ogg',
  'Swish 1': 'assets/fast_swish1.ogg',
  'Swish 2': 'assets/fast_swish2.ogg',
  'Swish 3': 'assets/fast_swish3.ogg',
  'Swish 4': 'assets/fast_swish4.ogg',
};

Future<void> runAudioPlayerApp(
  term.Terminal terminal,
  AudioService audioService,
  AssetLoader loadAsset, {
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
    widget: AudioPlayerAppWidget(
      terminal: terminal,
      audioService: audioService,
      loadAsset: loadAsset,
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

class AudioPlayerAppWidget extends StatefulWidget {
  final term.Terminal terminal;
  final AudioService audioService;
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
  final int totalTracks = playlist.length;
  late final List<SoundHandle?> loadedSounds = List.filled(totalTracks, null);

  late final List<String> names = playlist.keys.toList();
  late final List<String> paths = playlist.values.toList();

  String statusMessage =
      'Status: Idle. Use arrow keys/Tab to focus, Enter/Space to play.';

  Future<void> triggerPlay(int index) async {
    final name = names[index];
    final path = paths[index];

    if (!mounted) return;
    setState(() {
      statusMessage = 'Status: Preparing sound "$name"...';
    });

    try {
      if (loadedSounds[index] == null) {
        loadedSounds[index] = await widget.loadAsset(path);
      }

      final handle = loadedSounds[index];
      if (handle == null) {
        throw Exception('Failed to load sound');
      }

      if (!mounted) return;

      setState(() {
        widget.audioService.playSound(handle);
        statusMessage = 'Status: Playing sound "${names[index]}"!';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          statusMessage = 'Status: Error: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (event) {
        if (event.type == KeyType.character) {
          final key = event.key;
          if (key == 'q' || key == 'Q') {
            PromptScope.of(context)?.done();
            return true;
          }
          if (key.length == 1) {
            final codeUnit = key.codeUnits[0];
            if (codeUnit >= 49 && codeUnit <= 57) {
              final idx = codeUnit - 49;
              if (idx < totalTracks) {
                triggerPlay(idx);
                return true;
              }
            }
          }
        }
        return false;
      },
      child: Align(
        alignment: Alignment.center,
        child: Column([
          const Text(
            '=== TERMUI AUDIO COZY PLAYER ===',
            style: Style(
              foreground: CharmColors.julep,
              modifiers: Modifier.bold,
            ),
          ),
          const SizedBox(height: 1),
          const Text(
            'Use Tab/Arrows to navigate. Enter/Space/Click to select.',
          ),
          Text(
            "Or press keys 1-$totalTracks to play instantly. Press 'q' to quit.",
          ),
          const SizedBox(height: 1),
          FocusScope(
            child: Row([
              for (int i = 0; i < totalTracks; i++) ...[
                Button(
                  text: 'Play ${names[i]}',
                  onPressed: () => triggerPlay(i),
                ),
                const SizedBox(width: 2),
              ],
            ]),
          ),
          const SizedBox(height: 1),
          Text(statusMessage, style: const Style(foreground: Colors.yellow)),
        ]),
      ),
    );
  }
}
