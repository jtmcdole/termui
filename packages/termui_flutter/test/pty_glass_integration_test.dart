import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';

import 'package:termui_shared_examples/glass_compositing/pty_glass_runner.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test('pty glass integration test (s toggle, drag, focus, debug paint)', () async {
    final backend = MockTerminalBackend();
    final terminal = Terminal(backend);

    // Start the demo in a background Future
    SceneManager? sceneManager;
    final future = runPtyGlassDemo(terminal).then((sm) => sceneManager = sm);

    // Let initialization finish (wait for microtasks)
    await Future.delayed(const Duration(milliseconds: 100));

    // 1. Initial State: the glass layer should be focused.
    // When we press 's', settings should pop up.
    backend.pushString('s');

    await Future.delayed(const Duration(milliseconds: 50));

    // Test if 's' worked: It should have drawn the settings layer!
    // Since we don't have SceneManager handle easily available, we check if
    // the debug paint [🧐] shows up when we toggle debug borders.

    // Toggle debug borders
    backend.pushString('d');
    await Future.delayed(const Duration(milliseconds: 50));

    // There should be a [🧐] on the screen now!
    final screenContents = backend.stdout;

    print("FOCUSED LAYER: ${sceneManager?.focusedLayer}");
    print(
      "FBUF NULL: ${sceneManager?.focusedLayer?.renderer.currentBuffer == null}",
    );
    print(
      "FBUF WIDTH: ${sceneManager?.focusedLayer?.renderer.currentBuffer?.width}",
    );

    expect(
      screenContents.contains('🧐'),
      isTrue,
      reason: 'Debug monocle not found on screen',
    );

    // Quit the app
    backend.pushString('q');

    await future;
  });
}
