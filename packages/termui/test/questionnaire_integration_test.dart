import 'package:test/test.dart';
import 'package:termui_test/termui_test.dart';
import '../example/01_questionnaire_example.dart';

void main() {
  group('Questionnaire Integration Tests', () {
    test('Keyboard-only Traversal of Questionnaire Flow', () async {
      final tester = TerminalTester();
      tester.run(() async {
        final future = runQuestionnaire(tester.terminal);

        await tester.pump();

        // Screen 1: What is your name?
        print('--- SCREEN 1 ---');
        print(tester.screenshot());
        expect(find.textPattern('1. What is your name:'), findsOneWidget);

        // Type "John"
        tester.typeText('John');
        await tester.pumpAndSettle();
        print('--- SCREEN 1 AFTER TYPE ---');
        print(tester.screenshot());

        // Submit the name (Enter)
        tester.sendKey(LogicalKey.enter);
        await tester.pumpAndSettle();
        print('--- SCREEN 1 AFTER ENTER ---');
        print(tester.screenshot());

        // Screen 2: Favorite Text Editor
        expect(
          find.textPattern("2. What's your favorite text editor?"),
          findsOneWidget,
        );

        // Dispatch Right Arrow to select "VIM" (initial is "VScode" at index 0, Right Arrow selects "VIM" at index 1)
        tester.sendKey(LogicalKey.arrowRight);
        await tester.pumpAndSettle();
        print('--- SCREEN 2 AFTER RIGHT ARROW ---');
        print(tester.screenshot());

        // Submit the selection (Enter)
        tester.sendKey(LogicalKey.enter);
        await tester.pumpAndSettle();
        print('--- SCREEN 2 AFTER ENTER ---');
        print(tester.screenshot());

        // Screen 3: Preferred Operating System
        expect(
          find.textPattern("3. What is your preferred operating system?"),
          findsOneWidget,
        );

        // Dispatch Right Arrow to select "macOS" (initial is "Linux" at index 0, Right Arrow selects "macOS" at index 1)
        tester.sendKey(LogicalKey.arrowRight);
        await tester.pumpAndSettle();
        print('--- SCREEN 3 AFTER RIGHT ARROW ---');
        print(tester.screenshot());

        // Submit the selection (Enter)
        tester.sendKey(LogicalKey.enter);
        await tester.pumpAndSettle();

        // Wait for the whole sequence to finish
        await future;

        // Screen 4: Summary Section (printed via printWidget directly to stdout)
        expect(tester.backend.stdout, contains('🎉 QUESTIONNAIRE SUMMARY'));
        expect(tester.backend.stdout, contains('• Name: John'));
        expect(tester.backend.stdout, contains('• Favorite Editor: VIM'));
        expect(tester.backend.stdout, contains('• Operating System: macOS'));
      });
    });
  });
}
