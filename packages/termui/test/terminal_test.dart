import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';

void main() {
  group('Terminal.runGuarded Tests', () {
    test('runGuarded executes body and cleans up on success', () async {
      var executed = false;
      final result = await Terminal.runGuarded((terminal) {
        executed = true;
        return 42;
      });
      expect(executed, isTrue);
      expect(result, 42);
    });

    test('runGuarded cleans up and rethrows on exception', () async {
      expect(
        Terminal.runGuarded((terminal) {
          throw Exception('Test Crash');
        }),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'Terminal size and watchSize do not throw and return correct types',
      () async {
        final terminal = Terminal();
        final size = await terminal.size;
        expect(size.x, greaterThan(0));
        expect(size.y, greaterThan(0));

        final sizeStream = terminal.watchSize();
        expect(sizeStream, isA<Stream>());
        terminal.dispose();
      },
    );
  });
}
