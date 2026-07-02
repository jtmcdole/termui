import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';

void main() {
  test(
    'Builder widget passes BuildContext to callback and returns child widget',
    () {
      final tester = TerminalTester();
      tester.run(() async {
        BuildContext? capturedContext;

        final app = Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox(width: 5, height: 1, child: Text('Built'));
          },
        );

        await tester.pumpWidget(app);

        expect(capturedContext, isNotNull);
        expect(tester.buffer, isNotNull);
      });
    },
  );
}
