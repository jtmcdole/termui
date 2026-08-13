import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:example_flutter/src/tui_player/run_tui_player.dart';
import 'package:example_flutter/src/repository/repository.dart';
import 'dart:typed_data';

final class MockSavedCastsRepository implements SavedCastsRepository {
  @override
  Future<void> deleteCast(String name) async {}
  @override
  Future<List<String>> listCasts() async => [];
  @override
  Future<Uint8List?> loadBytes(String name) async => null;
  @override
  Future<String?> loadCast(String name) async => null;
  @override
  Future<void> saveBytes(String name, Uint8List content) async {}
  @override
  Future<void> saveCast(String name, String content) async {}
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('TUI Player Integration Tests', () {
    test('TUI Player starts, renders frame, and exits on Ctrl+C', () {
      FakeAsync().run((async) {
        final backend = MockTerminalBackend();
        final terminal = MockTerminal(backend);
        final mockRepo = MockSavedCastsRepository();

        var isDone = false;

        // Start the TUI player in the mock backend
        runAsciicastPlayerTui(
          terminal,
          repository: mockRepo,
        ).then((_) => isDone = true);

        // Let initial frame renders complete
        async.elapse(const Duration(milliseconds: 100));

        // Assert player has rendered header bar and control strings
        final allWrites = backend.writes.join('');
        expect(allWrites.contains('TERMUI TUI PLAYER'), isTrue);
        expect(
          allWrites.contains('PLAYING') || allWrites.contains('PAUSED'),
          isTrue,
        );
        expect(allWrites.contains('Space'), isTrue); // Hint text

        // Inject Ctrl+C to terminate the PromptRunner loop
        terminal.injectTestEvent(
          const ui.KeyEvent(
            'c',
            ui.KeyType.character,
            modifiers: {ui.Modifier.control},
          ),
        );
        async.flushMicrotasks();

        terminal.dispose();
        expect(isDone, isTrue);
      });
    });
  });
}
