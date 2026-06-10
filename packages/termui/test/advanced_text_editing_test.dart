import 'package:test/test.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/widget_toolkit.dart';

void main() {
  group('TextField Advanced Editing Shortcuts', () {
    test('Move back/forward one word (Ctrl+Left, Ctrl+Right)', () {
      final input = TextField(
        value: 'hello world standard',
        cursorPosition: 12,
      ); // cursor at 's' in 'standard'
      // hello world standard
      // 01234567890123456789

      // Word backward from 'standard' should go to 'world'
      input.handleKeyEvent(
        const KeyEvent('left', KeyType.left, modifiers: {Modifier.control}),
      );
      expect(input.cursorPosition, equals(6)); // index of 'w' in 'world'

      // Word forward from 'world' should go to end of 'world' (right after 'world', index 11)
      input.handleKeyEvent(
        const KeyEvent('right', KeyType.right, modifiers: {Modifier.control}),
      );
      expect(input.cursorPosition, equals(11)); // index after 'world'
    });

    test(
      'Move to start/end of line (Home, End, Ctrl+Shift+Left, Ctrl+Shift+Right)',
      () {
        final input = TextField(value: 'hello world', cursorPosition: 6);

        // Home
        input.handleKeyEvent(const KeyEvent('home', KeyType.home));
        expect(input.cursorPosition, equals(0));

        // End
        input.handleKeyEvent(const KeyEvent('end', KeyType.end));
        expect(input.cursorPosition, equals(11));

        // Reset to middle
        input.cursorPosition = 6;

        // Ctrl+Shift+Left
        input.handleKeyEvent(
          const KeyEvent(
            'left',
            KeyType.left,
            modifiers: {Modifier.control, Modifier.shift},
          ),
        );
        expect(input.cursorPosition, equals(0));

        // Ctrl+Shift+Right
        input.handleKeyEvent(
          const KeyEvent(
            'right',
            KeyType.right,
            modifiers: {Modifier.control, Modifier.shift},
          ),
        );
        expect(input.cursorPosition, equals(11));
      },
    );

    test('Delete word backward (Ctrl+W) on word and spaces', () {
      // 1. "thisisaword" with cursor in the middle
      final input1 = TextField(
        value: 'thisisaword',
        cursorPosition: 6,
      ); // cursor at 'a'
      input1.handleKeyEvent(
        const KeyEvent('w', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input1.value, equals('aword'));
      expect(input1.cursorPosition, equals(0));

      // 2. "hello   world" with cursor at end
      final input2 = TextField(value: 'hello   world', cursorPosition: 13);
      input2.handleKeyEvent(
        const KeyEvent('w', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input2.value, equals('hello   '));
      expect(input2.cursorPosition, equals(8));

      // 3. "hello   world" with cursor after spaces, before 'world'
      final input3 = TextField(
        value: 'hello   world',
        cursorPosition: 8,
      ); // cursor at 'w'
      input3.handleKeyEvent(
        const KeyEvent('w', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input3.value, equals('world'));
      expect(input3.cursorPosition, equals(0));
    });

    test('Delete word forward (Ctrl+Delete / Ctrl+D) on word and spaces', () {
      // 1. "thisisaword" with cursor in the middle (Ctrl+D)
      final input1 = TextField(
        value: 'thisisaword',
        cursorPosition: 6,
      ); // cursor at 'a'
      input1.handleKeyEvent(
        const KeyEvent('d', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input1.value, equals('thisis'));
      expect(input1.cursorPosition, equals(6));

      // 2. "thisisaword" with cursor in the middle (Ctrl+Delete)
      final input2 = TextField(
        value: 'thisisaword',
        cursorPosition: 6,
      ); // cursor at 'a'
      input2.handleKeyEvent(
        const KeyEvent('delete', KeyType.delete, modifiers: {Modifier.control}),
      );
      expect(input2.value, equals('thisis'));
      expect(input2.cursorPosition, equals(6));

      // 3. "   hello world" with cursor at start
      final input3 = TextField(value: '   hello world', cursorPosition: 0);
      input3.handleKeyEvent(
        const KeyEvent('d', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input3.value, equals(' world'));
      expect(input3.cursorPosition, equals(0));
    });

    test(
      'Delete to end of line (Ctrl+K) and start of line (Ctrl+Backspace)',
      () {
        // Ctrl+K
        final input1 = TextField(value: 'hello world', cursorPosition: 6);
        input1.handleKeyEvent(
          const KeyEvent('k', KeyType.character, modifiers: {Modifier.control}),
        );
        expect(input1.value, equals('hello '));
        expect(input1.cursorPosition, equals(6));

        // Ctrl+Backspace
        final input2 = TextField(value: 'hello world', cursorPosition: 6);
        input2.handleKeyEvent(
          const KeyEvent(
            'backspace',
            KeyType.backspace,
            modifiers: {Modifier.control},
          ),
        );
        expect(input2.value, equals('world'));
        expect(input2.cursorPosition, equals(0));
      },
    );

    test('Undo and Redo operation (Ctrl+Z, Ctrl+Y)', () {
      final input = TextField(value: 'hello', cursorPosition: 5);

      // Change text (insert '!')
      input.handleKeyEvent(const KeyEvent('!', KeyType.character));
      expect(input.value, equals('hello!'));
      expect(input.cursorPosition, equals(6));

      // Change text (delete word backward)
      input.handleKeyEvent(
        const KeyEvent('w', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input.value, equals(''));
      expect(input.cursorPosition, equals(0));

      // Undo once (should restore 'hello!')
      input.handleKeyEvent(
        const KeyEvent('z', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input.value, equals('hello!'));
      expect(input.cursorPosition, equals(6));

      // Undo again (should restore 'hello')
      input.handleKeyEvent(
        const KeyEvent('z', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input.value, equals('hello'));
      expect(input.cursorPosition, equals(5));

      // Redo once (should go back to 'hello!')
      input.handleKeyEvent(
        const KeyEvent('y', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input.value, equals('hello!'));
      expect(input.cursorPosition, equals(6));

      // Redo again (should go back to empty)
      input.handleKeyEvent(
        const KeyEvent('y', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(input.value, equals(''));
      expect(input.cursorPosition, equals(0));
    });

    test('Undo and Redo operation with Alt fallback (Alt+Z, Alt+Y)', () {
      final input = TextField(value: 'hello', cursorPosition: 5);

      // Change text (insert '!')
      input.handleKeyEvent(const KeyEvent('!', KeyType.character));
      expect(input.value, equals('hello!'));

      // Undo with Alt+Z
      input.handleKeyEvent(
        const KeyEvent('z', KeyType.character, modifiers: {Modifier.alt}),
      );
      expect(input.value, equals('hello'));

      // Redo with Alt+Y
      input.handleKeyEvent(
        const KeyEvent('y', KeyType.character, modifiers: {Modifier.alt}),
      );
      expect(input.value, equals('hello!'));
    });

    test('Multi-byte character / Emoji safety', () {
      // Input contains 3 grapheme clusters: '👋', '👨‍👩‍👧‍👦', '🚀'
      final input = TextField(value: '👋👨‍👩‍👧‍👦🚀', cursorPosition: 3);

      // Move left once (should jump over '🚀')
      input.handleKeyEvent(const KeyEvent('left', KeyType.left));
      expect(input.cursorPosition, equals(2));

      // Type character 'A'
      input.handleKeyEvent(const KeyEvent('A', KeyType.character));
      expect(input.value, equals('👋👨‍👩‍👧‍👦A🚀'));
      expect(input.cursorPosition, equals(3));

      // Backspace (should delete 'A')
      input.handleKeyEvent(const KeyEvent('backspace', KeyType.backspace));
      expect(input.value, equals('👋👨‍👩‍👧‍👦🚀'));
      expect(input.cursorPosition, equals(2));

      // Delete (should delete '🚀')
      input.handleKeyEvent(const KeyEvent('delete', KeyType.delete));
      expect(input.value, equals('👋👨‍👩‍👧‍👦'));
      expect(input.cursorPosition, equals(2));
    });
  });

  group('TextField Multiline Advanced Editing Shortcuts', () {
    test('Move back/forward one word (Ctrl+Left, Ctrl+Right)', () {
      final area = TextField(
        initialText: 'hello world\nstandard text',
        multiline: true,
      );
      area.cursorLine = 0;
      area.cursorColumn = 11; // End of 'hello world'

      // Word backward should move to start of 'world'
      area.handleKeyEvent(
        const KeyEvent('left', KeyType.left, modifiers: {Modifier.control}),
      );
      expect(area.cursorLine, equals(0));
      expect(area.cursorColumn, equals(6));

      // Word backward again should move to start of 'hello'
      area.handleKeyEvent(
        const KeyEvent('left', KeyType.left, modifiers: {Modifier.control}),
      );
      expect(area.cursorLine, equals(0));
      expect(area.cursorColumn, equals(0));

      // Word forward should move to end of 'hello'
      area.handleKeyEvent(
        const KeyEvent('right', KeyType.right, modifiers: {Modifier.control}),
      );
      expect(area.cursorLine, equals(0));
      expect(area.cursorColumn, equals(5));
    });

    test('Delete word backward/forward on line boundaries', () {
      final area = TextField(initialText: 'hello\nworld', multiline: true);
      area.cursorLine = 1;
      area.cursorColumn = 0;

      // Delete word backward at column 0 should merge with previous line
      area.handleKeyEvent(
        const KeyEvent('w', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(area.value, equals('helloworld'));
      expect(area.cursorLine, equals(0));
      expect(area.cursorColumn, equals(5));

      // Undo
      area.handleKeyEvent(
        const KeyEvent('z', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(area.value, equals('hello\nworld'));
      expect(area.cursorLine, equals(1));
      expect(area.cursorColumn, equals(0));

      // Move cursor to end of first line
      area.cursorLine = 0;
      area.cursorColumn = 5;

      // Delete word forward at end of line should merge with next line
      area.handleKeyEvent(
        const KeyEvent('d', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(area.value, equals('helloworld'));
      expect(area.cursorLine, equals(0));
      expect(area.cursorColumn, equals(5));
    });

    test('Delete to end of line (Ctrl+K) at end of line merges with next', () {
      final area = TextField(initialText: 'line1\nline2', multiline: true);
      area.cursorLine = 0;
      area.cursorColumn = 5; // End of 'line1'

      // Ctrl+K at end of line should delete newline and merge with next line
      area.handleKeyEvent(
        const KeyEvent('k', KeyType.character, modifiers: {Modifier.control}),
      );
      expect(area.value, equals('line1line2'));
      expect(area.cursorLine, equals(0));
      expect(area.cursorColumn, equals(5));
    });
  });
}
