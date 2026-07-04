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
    
    // Verify style (Red)
    final fg = buffer.getForeground(0, 0); // 'H'
    expect(fg, equals(Colors.red.argb));
  });
}
