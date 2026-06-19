import 'dart:async';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

class _TestStateful extends StatefulWidget {
  const _TestStateful({super.key});
  @override
  _TestState createState() => _TestState();
}
class _TestState extends State<_TestStateful> {
  int value = 42;
  @override
  Widget build(BuildContext context) => Text('Val: $value');
}

void main() {
  group('Core BuildContext and Key Tests', () {
    test('GlobalKey returns currentState', () async {
      final key = GlobalKey<_TestState>();
      final widget = _TestStateful(key: key);

      final tester = TerminalTester();
      await tester.pumpWidget(widget);

      expect(key.currentState, isNotNull);
      expect(key.currentState!.value, 42);

      // Test the other getter (currentContext)
      expect(key.currentContext, isNotNull);
    });

    test('ValueKey equality', () {
      final key1 = const ValueKey('foo');
      final key2 = const ValueKey('foo');
      final key3 = const ValueKey('bar');

      expect(key1, equals(key2));
      expect(key1 == key3, isFalse);
      expect(key1.hashCode, equals(key2.hashCode));
      expect(key1.toString(), contains('foo'));
    });

    test('BuildContext.current via Zone', () async {
      final widget = Text('Hello');
      final element = widget.createElement();

      runZoned(() {
        expect(BuildContext.current, equals(element));
      }, zoneValues: {#buildContext: element});
    });
  });
}
