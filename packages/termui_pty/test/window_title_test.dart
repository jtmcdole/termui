import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

void main() {
  group('VirtualTerminal OSC 0/1/2 and CSI 22t/23t title stack', () {
    test(
      'OSC 0 sets both iconTitle and windowTitle, OSC 1/2 set individually',
      () {
        final titles = <String>[];
        final vt = VirtualTerminal(width: 20, height: 5)
          ..onTitleChanged = titles.add;

        vt.writeString('\x1b]0;Both Titles\x07');
        expect(vt.windowTitle, equals('Both Titles'));
        expect(vt.iconTitle, equals('Both Titles'));
        expect(titles, equals(['Both Titles']));

        vt.writeString('\x1b]1;Icon Only\x1b\\');
        expect(vt.iconTitle, equals('Icon Only'));
        expect(vt.windowTitle, equals('Both Titles'));
        expect(titles, hasLength(1));

        vt.writeString('\x1b]2;Window Only\x07');
        expect(vt.windowTitle, equals('Window Only'));
        expect(vt.iconTitle, equals('Icon Only'));
        expect(titles, equals(['Both Titles', 'Window Only']));
      },
    );

    test('CSI 22t and 23t push and pop window and icon titles', () {
      final titles = <String>[];
      final vt = VirtualTerminal(width: 20, height: 5)
        ..onTitleChanged = titles.add;

      vt.writeString('\x1b]0;Shell\x07');
      vt.writeString('\x1b[22;0t'); // Push both
      vt.writeString('\x1b]0;Vim\x07');
      vt.writeString('\x1b[22;2t'); // Push window title only
      vt.writeString('\x1b]2;Vim - Help\x07');
      vt.writeString('\x1b]1;Custom Icon\x07');

      expect(vt.windowTitle, equals('Vim - Help'));
      expect(vt.iconTitle, equals('Custom Icon'));

      // Pop window title only (23;2t) -> restores 'Vim'
      vt.writeString('\x1b[23;2t');
      expect(vt.windowTitle, equals('Vim'));
      expect(vt.iconTitle, equals('Custom Icon'));

      // Pop both (23;0t) -> restores 'Shell' for both
      vt.writeString('\x1b[23;0t');
      expect(vt.windowTitle, equals('Shell'));
      expect(vt.iconTitle, equals('Shell'));
      expect(titles.last, equals('Shell'));
    });

    test('RIS (ESC c) resets titles and clears stacks', () {
      final vt = VirtualTerminal(width: 20, height: 5);
      vt.writeString('\x1b]0;Initial\x07\x1b[22t\x1b]0;Changed\x07');
      expect(vt.windowTitle, equals('Changed'));

      vt.writeString('\x1bc');
      expect(vt.windowTitle, isEmpty);
      expect(vt.iconTitle, isEmpty);

      // Popping after RIS should be a no-op
      vt.writeString('\x1b[23t');
      expect(vt.windowTitle, isEmpty);
    });
  });
}
