import 'dart:io';
import 'package:test/test.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/input_parser.dart';

void main() {
  late InputParser parser;

  setUp(() {
    parser = InputParser(isWindows: Platform.isWindows);
  });

  group('Keyboard Parsing Tests', () {
    test('Normal characters', () {
      final events = parser.parse('abc'.codeUnits);
      expect(events.length, 3);
      expect(events[0], const KeyEvent('a', KeyType.character));
      expect(events[1], const KeyEvent('b', KeyType.character));
      expect(events[2], const KeyEvent('c', KeyType.character));
    });

    test('Control keys (backspace, enter, tab, escape)', () {
      if (Platform.isWindows) {
        expect(parser.parse([8]), [
          const KeyEvent('backspace', KeyType.backspace),
        ]);
        expect(parser.parse([127]), [
          const KeyEvent(
            'backspace',
            KeyType.backspace,
            modifiers: {Modifier.control},
          ),
        ]);
      } else {
        expect(parser.parse([127]), [
          const KeyEvent('backspace', KeyType.backspace),
        ]);
        expect(parser.parse([8]), [
          const KeyEvent(
            'backspace',
            KeyType.backspace,
            modifiers: {Modifier.control},
          ),
        ]);
      }
      expect(parser.parse([9]), [const KeyEvent('\t', KeyType.tab)]);
      expect(parser.parse([10]), [const KeyEvent('\n', KeyType.enter)]);
      expect(parser.parse([13]), [const KeyEvent('\n', KeyType.enter)]);
      expect(parser.parse([27]), [const KeyEvent('escape', KeyType.escape)]);
    });

    test('Shift+Tab (backtab)', () {
      expect(parser.parse('\x1b[Z'.codeUnits), [
        const KeyEvent('backtab', KeyType.tab, modifiers: {Modifier.shift}),
      ]);
    });

    test('Ctrl+character shortcut', () {
      // Ctrl+A = 1
      expect(parser.parse([1]), [
        const KeyEvent('a', KeyType.character, modifiers: {Modifier.control}),
      ]);
      // Ctrl+C = 3
      expect(parser.parse([3]), [
        const KeyEvent('c', KeyType.character, modifiers: {Modifier.control}),
      ]);
    });

    test('Alt+character shortcut', () {
      // ESC + 'a'
      expect(parser.parse([27, 97]), [
        const KeyEvent('a', KeyType.character, modifiers: {Modifier.alt}),
      ]);
    });

    test('Arrow keys without modifiers', () {
      expect(parser.parse('\x1b[A'.codeUnits), [
        const KeyEvent('up', KeyType.up),
      ]);
      expect(parser.parse('\x1b[B'.codeUnits), [
        const KeyEvent('down', KeyType.down),
      ]);
      expect(parser.parse('\x1b[C'.codeUnits), [
        const KeyEvent('right', KeyType.right),
      ]);
      expect(parser.parse('\x1b[D'.codeUnits), [
        const KeyEvent('left', KeyType.left),
      ]);
    });

    test('Arrow keys with modifiers (Ctrl + Up)', () {
      expect(parser.parse('\x1b[1;5A'.codeUnits), [
        const KeyEvent('up', KeyType.up, modifiers: {Modifier.control}),
      ]);
      expect(parser.parse('\x1b[1;6B'.codeUnits), [
        const KeyEvent(
          'down',
          KeyType.down,
          modifiers: {Modifier.control, Modifier.shift},
        ),
      ]);
    });

    test('Function keys (~ termination)', () {
      expect(parser.parse('\x1b[15~'.codeUnits), [
        const KeyEvent('f5', KeyType.f5),
      ]);
      expect(parser.parse('\x1b[17;5~'.codeUnits), [
        const KeyEvent('f6', KeyType.f6, modifiers: {Modifier.control}),
      ]);
    });

    test('SS3 function keys (ESC O P)', () {
      expect(parser.parse('\x1bOP'.codeUnits), [
        const KeyEvent('f1', KeyType.f1),
      ]);
    });

    test('Incomplete stream parsing', () {
      // Feed half a CSI sequence
      var events = parser.parse('\x1b[1;'.codeUnits);
      expect(events, isEmpty);

      // Feed the rest
      events = parser.parse('5A'.codeUnits);
      expect(events, [
        const KeyEvent('up', KeyType.up, modifiers: {Modifier.control}),
      ]);
    });
  });

  group('Mouse Parsing Tests', () {
    test('SGR Mouse Protocol', () {
      // Left click press at (10, 20) -> button 0
      expect(parser.parse('\x1b[<0;10;20M'.codeUnits), [
        const MouseEvent(
          x: 10,
          y: 20,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
      ]);

      // Left click release at (10, 20) -> button 0 ending with m
      expect(parser.parse('\x1b[<0;10;20m'.codeUnits), [
        const MouseEvent(
          x: 10,
          y: 20,
          button: MouseButton.left,
          type: MouseEventType.release,
        ),
      ]);

      // Left click drag at (11, 20) -> button 32
      expect(parser.parse('\x1b[<32;11;20M'.codeUnits), [
        const MouseEvent(
          x: 11,
          y: 20,
          button: MouseButton.left,
          type: MouseEventType.drag,
        ),
      ]);

      // Hover/move at (12, 20) -> button 35
      expect(parser.parse('\x1b[<35;12;20M'.codeUnits), [
        const MouseEvent(
          x: 12,
          y: 20,
          button: MouseButton.none,
          type: MouseEventType.move,
        ),
      ]);

      // Scroll up -> button 64
      expect(parser.parse('\x1b[<64;5;5M'.codeUnits), [
        const MouseEvent(
          x: 5,
          y: 5,
          button: MouseButton.wheelUp,
          type: MouseEventType.press,
        ),
      ]);

      // Scroll down with Control modifier -> button 65 + 16 = 81
      expect(parser.parse('\x1b[<81;5;5M'.codeUnits), [
        const MouseEvent(
          x: 5,
          y: 5,
          button: MouseButton.wheelDown,
          type: MouseEventType.press,
          modifiers: {Modifier.control},
        ),
      ]);
    });

    test('X10 Mouse Protocol', () {
      // X10 starts with ESC [ M, followed by 3 bytes: button+32, col+32, row+32
      // Left press at (10, 20) -> button = 0, col = 10, row = 20
      // bytes: 27, 91, 77, 32, 42, 52
      expect(parser.parse([27, 91, 77, 32, 42, 52]), [
        const MouseEvent(
          x: 10,
          y: 20,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
      ]);

      // Release at (10, 20) -> buttonCode = 3
      // bytes: 27, 91, 77, 35, 42, 52
      expect(parser.parse([27, 91, 77, 35, 42, 52]), [
        const MouseEvent(
          x: 10,
          y: 20,
          button: MouseButton.none,
          type: MouseEventType.release,
        ),
      ]);
    });
  });

  group('Focus and Paste Parsing Tests', () {
    test('Focus in and out', () {
      expect(parser.parse('\x1b[I'.codeUnits), [const FocusInEvent()]);
      expect(parser.parse('\x1b[O'.codeUnits), [const FocusOutEvent()]);
    });

    test('Bracketed paste protocol', () {
      // Feed paste start
      expect(parser.parse('\x1b[200~'.codeUnits), isEmpty);
      // Feed pasted characters in chunks
      expect(parser.parse('hello '.codeUnits), isEmpty);
      expect(parser.parse('world'.codeUnits), isEmpty);
      // Feed paste end
      expect(parser.parse('\x1b[201~'.codeUnits), [
        const PasteEvent('hello world'),
      ]);
    });
  });
}
