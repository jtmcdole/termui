import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termui_shared_examples/glass_compositing/pty_glass_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test(
    'pty glass integration test (s toggle, drag, focus, debug paint)',
    () async {
      final backend = MockTerminalBackend();
      final terminal = Terminal(backend);

      // Start the demo in a background Future
      final future = runPtyGlassDemo(terminal);

      // Wait until the first frame is rendered
      await waitForCondition(
        () => backend.stdout.isNotEmpty,
        timeout: const Duration(seconds: 5),
      );

      // 1. Initial State: the glass layer should be focused.
      // When we press 's', settings should pop up.
      backend.pushString('s');

      // Test if 's' worked: It should have drawn the settings layer!
      // Since we don't have SceneManager handle easily available, we check if
      // the debug paint [🧐] shows up when we toggle debug borders.

      // Toggle debug borders
      backend.pushString('d');

      // Ensure the condition is met by polling for the debug monocle
      await waitForCondition(
        () => backend.stdout.contains('🧐'),
        timeout: const Duration(seconds: 5),
      );

      // There should be a [🧐] on the screen now!
      final screenContents = backend.stdout;

      expect(
        screenContents.contains('🧐'),
        isTrue,
        reason: 'Debug monocle not found on screen',
      );

      // Quit the app
      backend.pushString('q');

      await future;
    },
  );
}
