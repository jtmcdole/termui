import 'dart:async';
import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/ui/buffer.dart';
import 'package:termui_shared_examples/widget_book/widget_book_runner.dart';
import 'package:termui_shared_examples/widget_book/widget_book_platform.dart';

class FakeTerminalBackend implements TerminalBackend {
  final StreamController<List<int>> _inputController =
      StreamController<List<int>>();
  final List<String> writtenData = [];
  final Point<int> _size = const Point(80, 24);

  @override
  bool get isWindows => false;

  @override
  Stream<List<int>> get rawInput => _inputController.stream;

  @override
  void write(String data) {
    writtenData.add(data);
  }

  @override
  Point<int> get size => _size;

  @override
  Stream<Point<int>> watchSize() => const Stream.empty();

  @override
  void enableRawMode() {}

  @override
  void disableRawMode() {}

  @override
  void dispose() {
    _inputController.close();
  }

  void injectBytes(List<int> bytes) {
    _inputController.add(bytes);
  }
}

class TestWidgetBookPlatform implements WidgetBookPlatform {
  @override
  bool get shouldRenderToTerminal => false;

  @override
  void onFrameRedrawn(Buffer buffer) {}

  @override
  void startTicker(void Function(Duration elapsed) onTick) {}

  @override
  void stopTicker() {}

  @override
  bool handleKeyEvent(Terminal terminal, ui.KeyEvent event) => false;

  @override
  void onExit() {}
}

class MockTerminal extends Terminal {
  final _eventsController = StreamController<ui.InputEvent>.broadcast();

  MockTerminal(super.backend);

  @override
  Stream<ui.InputEvent> get events => _eventsController.stream;

  void injectTestEvent(ui.InputEvent event) {
    _eventsController.add(event);
  }

  @override
  void dispose() {
    _eventsController.close();
    super.dispose();
  }
}

void main() {
  group('Widget Book Runner Mouse Event Tests', () {
    test('Sidebar navigation clicks change page correctly', () async {
      final backend = FakeTerminalBackend();
      final terminal = Terminal(backend);
      final platform = TestWidgetBookPlatform();

      // Run widget book runner
      final bookFuture = runWidgetBookShared(terminal, platform);

      // Wait for initialization
      await Future.delayed(const Duration(milliseconds: 50));

      // Clear written data from initial frame renders
      backend.writtenData.clear();

      // Click on the second sidebar item (Data Displays, index 1, 1-indexed row 4)
      // SGR mouse press sequence: \x1b[<0;5;4M
      backend.injectBytes('\x1b[<0;5;4M'.codeUnits);

      // Wait for event processing
      await Future.delayed(const Duration(milliseconds: 50));

      // Changing page should trigger terminal.resetMousePointer() which writes '\x1b]22;\x1b\\'
      expect(
        backend.writtenData.any((s) => s.contains('\x1b]22;\x1b\\')),
        isTrue,
      );

      terminal.dispose();
      await bookFuture;
    });

    test('Ctrl+C terminates widget book runner loop', () async {
      // 1. Test standard Ctrl+C parsed from byte stream
      {
        final backend = FakeTerminalBackend();
        final terminal = Terminal(backend);
        final platform = TestWidgetBookPlatform();

        final bookFuture = runWidgetBookShared(terminal, platform);
        await Future.delayed(const Duration(milliseconds: 50));

        // Inject Ctrl+C bytes (code 3)
        backend.injectBytes([3]);

        await bookFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException(
            'Widget book did not exit on Ctrl+C bytes',
          ),
        );
        terminal.dispose();
      }

      // 2. Test Flutter-injected Ctrl+C KeyEvent using MockTerminal
      {
        final backend = FakeTerminalBackend();
        final terminal = MockTerminal(backend);
        final platform = TestWidgetBookPlatform();

        final bookFuture = runWidgetBookShared(terminal, platform);
        await Future.delayed(const Duration(milliseconds: 50));

        // Inject Flutter-style Ctrl+C KeyEvent
        terminal.injectTestEvent(
          const ui.KeyEvent(
            '\x03',
            ui.KeyType.character,
            modifiers: {ui.Modifier.control},
          ),
        );

        await bookFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException(
            'Widget book did not exit on injected KeyEvent',
          ),
        );
        terminal.dispose();
      }
    });
  });
}
