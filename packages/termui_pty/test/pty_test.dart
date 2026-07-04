import 'package:test/test.dart';
import 'dart:convert';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_pty/src/virtual_terminal.dart';
import 'package:termui/termui.dart';

void main() {
  group('VirtualTerminal Tests', () {
    test('handles basic ANSI text', () {
      final vt = VirtualTerminal(width: 80, height: 24);
      vt.write(utf8.encode('Hello, World!'));
      expect(vt.buffer.getCharacter(0, 0), 'H');
      expect(vt.buffer.getCharacter(1, 0), 'e');
    });

    test('handles background transparency', () {
      final vt = VirtualTerminal(
        width: 80,
        height: 24,
        transparentBackground: true,
      );
      vt.write(utf8.encode('a \x1b[48;2;255;0;0mb'));

      // 'a' has transparent modifier
      expect(
        vt.buffer.getModifiers(0, 0) & Modifier.transparent,
        0,
      ); // Not space
      expect(
        vt.buffer.getModifiers(1, 0) & Modifier.transparent,
        Modifier.transparent,
      ); // Space

      // 'b' does not because it has a background color
      expect(vt.buffer.getModifiers(2, 0) & Modifier.transparent, 0);
    });

    test('resizes properly and maintains transparency', () {
      final vt = VirtualTerminal(
        width: 10,
        height: 10,
        transparentBackground: true,
      );
      vt.resize(20, 20);

      // New cells should be transparent
      expect(
        vt.buffer.getModifiers(15, 15) & Modifier.transparent,
        Modifier.transparent,
      );
      expect(vt.buffer.getBackground(15, 15), 0);
    });
  });
}
