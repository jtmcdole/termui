import 'package:termui/termui.dart';
import 'package:termui_pty/src/virtual_terminal.dart';
import 'package:test/test.dart';

void main() {
  test('VirtualTerminal processes ANSI sequences into Buffer', () {
    final terminal = VirtualTerminal(width: 10, height: 5);

    // Simulate raw byte stream from PTY
    // 1. Move to 1,1
    // 2. Set color to red (31)
    // 3. Print 'Hello'
    final sequence = '\x1b[1;1H\x1b[31mHello';
    terminal.write(sequence.codeUnits);

    final buffer = terminal.buffer;

    // Verify content
    expect(buffer.characters.join(), startsWith('Hello'));

    // Verify style (Red - mapped to 0xAA0000 in standard 16 colors)
    final fg = buffer.getForeground(0, 0); // 'H'
    expect(fg, equals(const Color(170, 0, 0).argb));
  });

  test('VirtualTerminal handles multi-byte wide graphemes (emojis)', () {
    final terminal = VirtualTerminal(width: 10, height: 5);

    // '\x1b[1;1H' = Move cursor to 1,1
    // '🍎' = Apple emoji (2 code units, wide grapheme taking 2 columns)
    final sequence = '\x1b[1;1H🍎';
    terminal.write(sequence.codeUnits);

    final buffer = terminal.buffer;

    // The apple emoji should be stored in the first cell (index 0)
    // The second cell (index 1) should be an empty string placeholder for wide characters
    expect(buffer.characters[0], equals('🍎'));
    expect(buffer.characters[0].length, equals(2)); // Surrogate pair
    expect(buffer.characters[1], equals('')); // Spacer cell
    expect(buffer.characters[2], equals(' ')); // Rest of the row is empty space
  });
}
