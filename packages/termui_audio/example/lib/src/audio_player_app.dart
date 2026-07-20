// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:termui_audio/termui_audio.dart';

typedef AssetLoader = Future<SoundHandle> Function(String assetPath);

const Map<String, String> playlist = {
  'Clouds': 'assets/DontFallOffTheClouds.ogg',
  'Sound 1': 'assets/sound1.ogg',
  'Sound 2': 'assets/sound2.ogg',
  'Sound 3': 'assets/sound3.ogg',
  'Sound 4': 'assets/sound4.ogg',
};

Future<void> runAudioPlayerApp(
  term.Terminal terminal,
  AudioService audioService,
  AssetLoader loadAsset, {
  void Function(Buffer)? onFrameRedrawn,
}) async {
  final initialSize = await terminal.size;
  int width = initialSize.x;
  int height = initialSize.y;
  var buffer = Buffer(width, height);
  var renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);

  terminal.enterAlternateScreen();
  terminal.hideCursor();

  final names = playlist.keys.toList();
  final paths = playlist.values.toList();
  final int totalTracks = playlist.length;

  int selectedIndex = 0;
  List<SoundHandle?> loadedSounds = List.filled(totalTracks, null);
  List<bool> playingSounds = List.filled(totalTracks, false);
  String statusMessage =
      'Status: Idle. Use arrow keys/Tab to focus, Enter/Space to play.';

  late final BuildOwner buildOwner;
  late final ElementWidget elementWrapper;

  void drawFrame() {
    buffer.clear();
    buffer.fillAttributes(char: ' ', fg: 0, bg: 0, modifiers: 0);
    elementWrapper.layout(
      BoxConstraints.tight(Size(width, height)),
      buildOwner,
    );
    elementWrapper.paint(buffer, Offset.zero);

    final sb = StringBuffer();
    renderer.render(buffer, sb);
    if (sb.isNotEmpty) {
      if (onFrameRedrawn != null) {
        onFrameRedrawn(buffer);
      } else {
        terminal.backend.write(sb.toString());
      }
    }
  }

  bool frameScheduled = false;
  void scheduleRepaint() {
    if (!frameScheduled) {
      frameScheduled = true;
      scheduleMicrotask(() {
        drawFrame();
        frameScheduled = false;
      });
    }
  }

  buildOwner = BuildOwner(onNeedVisualUpdate: scheduleRepaint);

  Future<void> triggerPlay(int index) async {
    final name = names[index];
    final path = paths[index];
    statusMessage = 'Status: Preparing sound "$name"...';
    scheduleRepaint();
    try {
      if (loadedSounds[index] == null) {
        loadedSounds[index] = await loadAsset(path);
      }

      final handle = loadedSounds[index];
      if (handle == null) {
        throw Exception('Failed to load sound');
      }
      if (playingSounds[index]) {
        await audioService.stopSound(handle);
        playingSounds[index] = false;
        statusMessage = 'Status: Stopped sound "$name".';
      } else {
        // Stop any other playing sound
        for (int i = 0; i < totalTracks; i++) {
          final s = loadedSounds[i];
          if (playingSounds[i] && s != null) {
            await audioService.stopSound(s);
            playingSounds[i] = false;
          }
        }
        await audioService.playSound(handle);
        playingSounds[index] = true;
        statusMessage = 'Status: Playing sound "$name"!';
      }
    } catch (e) {
      statusMessage = 'Status: Error: $e';
    }
    scheduleRepaint();
  }

  final appWidget = Align(
    alignment: Alignment.center,
    child: Column([
      const Text(
        '=== TERMUI AUDIO COZY PLAYER ===',
        style: Style(foreground: CharmColors.julep, modifiers: Modifier.bold),
      ),
      const SizedBox(height: 1),
      const Text('Use Arrow keys / Tab to navigate. Enter/Space to select.'),
      Text(
        "Or press keys 1-$totalTracks to play instantly. Press 'q' to quit.",
      ),
      const SizedBox(height: 1),
      StatefulBuilder(
        builder: (context, setState) {
          return Row([
            for (int i = 0; i < totalTracks; i++) ...[
              Button(
                text: playingSounds[i]
                    ? 'Stop ${names[i]}'
                    : 'Play ${names[i]}',
                focused: selectedIndex == i,
                onPressed: () => triggerPlay(i),
              ),
              const SizedBox(width: 2),
            ],
          ]);
        },
      ),
      const SizedBox(height: 1),
      StatefulBuilder(
        builder: (context, setState) {
          return Text(
            statusMessage,
            style: const Style(foreground: Colors.yellow),
          );
        },
      ),
    ]),
  );

  elementWrapper = ElementWidget(appWidget);
  drawFrame();

  final sizeSubscription = terminal.watchSize().listen((size) {
    width = size.x;
    height = size.y;
    buffer.resize(width, height);
    renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);
    drawFrame();
  });

  try {
    await for (final event in terminal.events) {
      if (event is term.KeyEvent) {
        final key = event.key;
        if (key == 'q' ||
            key == 'Q' ||
            (key.length == 1 && key.codeUnits[0] == 3)) {
          break; // Quit or Ctrl+C
        }

        // Arrow navigation
        if (event.baseKey == term.TermKey.right ||
            event.baseKey == term.TermKey.down ||
            key == '\t') {
          selectedIndex = (selectedIndex + 1) % totalTracks;
          scheduleRepaint();
        } else if (event.baseKey == term.TermKey.left ||
            event.baseKey == term.TermKey.up) {
          selectedIndex = (selectedIndex - 1 + totalTracks) % totalTracks;
          scheduleRepaint();
        } else if (event.baseKey == term.TermKey.enter || key == ' ') {
          await triggerPlay(selectedIndex);
        } else {
          // Dynamic numeric hotkeys '1' - '9'
          if (key.length == 1) {
            final codeUnit = key.codeUnits[0];
            if (codeUnit >= 49 && codeUnit <= 57) {
              final idx = codeUnit - 49;
              if (idx < totalTracks) {
                selectedIndex = idx;
                await triggerPlay(idx);
              }
            }
          }
        }
      }
    }
  } finally {
    sizeSubscription.cancel();
    elementWrapper.element?.unmount();
    terminal.showCursor();
    terminal.exitAlternateScreen();
    terminal.resetStyle();
  }
}
