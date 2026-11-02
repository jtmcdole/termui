import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  test('waitForFontsToLoad is exported by public API', () {
    // This will fail to compile if the function is not exported.
    expect(waitForFontsToLoad, isNotNull);
  });

  test('saveFile rejects path traversal and invalid file names', () async {
    for (final invalid in ['', '.', '..', '../secret.txt', r'..\secret.txt']) {
      await expectLater(
        saveFile(invalid, const [1, 2, 3]),
        throwsArgumentError,
        reason: 'Expected ArgumentError for basename="$invalid"',
      );
    }
  });

  test(
    'FlutterTerminal uses synchronous typed clipboard side-channel and ignores OSC 52 in backend.write',
    () async {
      final terminal = FlutterTerminal();
      final writes = <String>[];
      var pasteRequestCount = 0;

      final clipSub = terminal.clipboardChanges.listen(writes.add);
      final pasteSub = terminal.pasteRequests.listen(
        (_) => pasteRequestCount++,
      );

      // Synchronous delivery without awaiting microtasks.
      terminal.setClipboard('copied from TUI 🚀');
      terminal.requestPaste();
      expect(writes, equals(['copied from TUI 🚀']));
      expect(pasteRequestCount, equals(1));

      // Rendered/backend OSC 52 bytes must NEVER trigger clipboard writes or paste requests.
      terminal.backend.write('\x1b]52;c;?\x07\x1b]52;c;aGk=\x1b\\');
      await Future<void>.delayed(Duration.zero);
      expect(writes, equals(['copied from TUI 🚀']));
      expect(pasteRequestCount, equals(1));

      await clipSub.cancel();
      await pasteSub.cancel();
      terminal.dispose();
    },
  );
}
