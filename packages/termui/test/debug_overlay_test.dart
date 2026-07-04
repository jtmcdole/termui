import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('Debug Overlay & Touch Visualizer', () {
    setUp(() {
      debugShowTouchesEnabled = false;
      debugPaintHoverEnabled = false;
    });

    test('Renders expanding Braille circles on mouse press', () {
      final tester = TerminalTester();
      tester.run(() async {
        debugShowTouchesEnabled = true;

        final manager = SceneManager(tester.terminal);
        manager.render(); // Initial render

        final pressEvent = MouseEvent(
          x: 5,
          y: 5,
          globalX: 5,
          globalY: 5,
          button: MouseButton.left,
          type: MouseEventType.press,
          modifiers: const {},
        );
        manager.handleMouseEvent(pressEvent);
        manager.render();

        final backend = tester.terminal.backend as BufferedTerminalBackend;
        expect(backend.buffer!.getCharacter(4, 4), '❶');

        // Fast forward time by 200ms
        await tester.pump(const Duration(milliseconds: 200));
        manager.render();

        // Fast forward time by 600ms (decay threshold is 500ms)
        await tester.pump(const Duration(milliseconds: 600));
        manager.render();

        expect(backend.buffer!.getCharacter(4, 4), isNot('❶'));
      });
    });

    test('Toggles debug overlay via hotkey', () {
      final tester = TerminalTester();
      tester.run(() async {
        final manager = SceneManager(tester.terminal);
        
        expect(debugShowTouchesEnabled, isFalse);
        
        final hotkeyEvent = KeyEvent('F10', debugToggleHotkey!);
        manager.handleKeyEvent(hotkeyEvent);
        
        expect(debugShowTouchesEnabled, isTrue);
        expect(debugPaintHoverEnabled, isTrue);
        
        manager.handleKeyEvent(hotkeyEvent);

        expect(debugShowTouchesEnabled, isFalse);
        expect(debugPaintHoverEnabled, isFalse);
      });
    });
  });
}
