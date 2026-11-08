import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

import '../example/scroll_input_demo.dart';

String _bufferToText(Buffer? buffer) {
  if (buffer == null) return '';
  final sb = StringBuffer();
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      sb.write(buffer.getCharacter(x, y));
    }
    sb.writeln();
  }
  return sb.toString();
}

void main() {
  group('scroll_input_demo integration tests', () {
    test(
      'completes full form workflow: text input, tab scroll, toggles, modal submit, and reset',
      () {
        final tester = TerminalTester();
        tester.run(() async {
          final demoFuture = runScrollInputDemo(tester.terminal);
          await tester.pumpAndSettle();

          // 1. Initial state renders dashboard header and Email placeholder
          var screen = _bufferToText(tester.backend.buffer);
          expect(screen, contains('USER PROFILE DASHBOARD'));
          expect(screen, contains('Enter email address...'));

          // 2. Type into Email TextField (focusedIndex == 0)
          tester.typeText('ada@lovelace.org');
          await tester.pumpAndSettle();
          screen = _bufferToText(tester.backend.buffer);
          expect(screen, contains('ada@lovelace.org'));

          // 3. Tab to Bio TextField (focusedIndex == 1) and type multiline bio
          tester.sendKey(LogicalKey.tab);
          await tester.pumpAndSettle();
          tester.typeText('Analytical Engine');
          tester.sendKey(LogicalKey.enter);
          tester.typeText('Pioneer');
          await tester.pumpAndSettle();
          screen = _bufferToText(tester.backend.buffer);
          expect(screen, contains('Analytical Engine'));
          expect(screen, contains('Pioneer'));

          // 4. Tab to Newsletter Checkbox (focusedIndex == 2) and toggle on
          tester.sendKey(LogicalKey.tab);
          await tester.pumpAndSettle();
          tester.sendKey(LogicalKey.character(' '));
          await tester.pumpAndSettle();
          screen = _bufferToText(tester.backend.buffer);
          expect(screen, contains('[X] Subscribe to Newsletter'));

          // 5. Tab to Light Mode Radio (focusedIndex == 3) and select it
          tester.sendKey(LogicalKey.tab);
          await tester.pumpAndSettle();
          tester.sendKey(LogicalKey.character(' '));
          await tester.pumpAndSettle();

          // 6. Tab past Dark Mode Radio (4) to Sound FX Switch (5) and toggle off
          tester.sendKey(LogicalKey.tab);
          await tester.pumpAndSettle();
          tester.sendKey(LogicalKey.tab);
          await tester.pumpAndSettle();
          tester.sendKey(LogicalKey.character(' '));
          await tester.pumpAndSettle();

          // 7. Tab to SUBMIT FORM DATA Button (focusedIndex == 6);
          // viewport scrolls automatically to bring button into view
          tester.sendKey(LogicalKey.tab);
          await tester.pumpAndSettle();
          screen = _bufferToText(tester.backend.buffer);
          expect(screen, contains('[ SUBMIT FORM DATA ]'));
          expect(screen, contains('(*) Light Mode Theme'));
          expect(screen, contains('[○─] Sound FX Output'));

          // 8. Activate SUBMIT FORM DATA button to open Submission Success modal
          tester.sendKey(LogicalKey.enter);
          await tester.pumpAndSettle();
          screen = _bufferToText(tester.backend.buffer);
          expect(screen, contains('Submission Success'));
          expect(screen, contains('Form Submitted Successfully!'));
          expect(screen, contains('Email: ada@lovelace.org'));
          expect(screen, contains('Newsletter: Yes'));

          // 9. Scroll down inside modal to verify Theme and Sound FX lines are reachable
          tester.sendKey(LogicalKey.arrowDown);
          await tester.pumpAndSettle();
          screen = _bufferToText(tester.backend.buffer);
          expect(screen, contains('Theme: light'));

          tester.sendKey(LogicalKey.arrowDown);
          await tester.pumpAndSettle();
          screen = _bufferToText(tester.backend.buffer);
          expect(screen, contains('Sound FX: false'));

          // 10. Press Enter to dismiss modal and reset form back to defaults
          tester.sendKey(LogicalKey.enter);
          await tester.pumpAndSettle();
          screen = _bufferToText(tester.backend.buffer);
          expect(screen, isNot(contains('Form Submitted Successfully!')));
          expect(screen, contains('Enter email address...'));
          expect(screen, contains('[ ] Subscribe to Newsletter'));

          // 11. Press Escape to exit the demo cleanly
          tester.sendKey(LogicalKey.escape);
          await tester.pumpAndSettle();
          await demoFuture;
        });
      },
    );
  });
}
