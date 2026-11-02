import 'package:termui/termui.dart';
import 'package:test/test.dart';

String _readBufferRow(Buffer buffer, int row) =>
    [for (var x = 0; x < buffer.width; x++) buffer.getCharacter(x, row)].join();

void main() {
  group('Focus Tests', () {
    setUp(() => FocusManager.instance.setPrimaryFocus(null));

    test('Focus widget autofocuses and callbacks', () async {
      KeyEvent? handledEvent;
      bool? focusedState;

      final focusWidget = Focus(
        autofocus: true,
        onKeyEvent: (evt) {
          handledEvent = evt;
          return true;
        },
        onFocusChange: (has) {
          focusedState = has;
        },
        child: const Text('Focused Child'),
      );

      final element = focusWidget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 20)));
      await Future<void>.delayed(Duration.zero);
      final buffer = Buffer.blank(20, 20);
      element.paint(buffer, Offset.zero);

      final primary = FocusManager.instance.primaryFocus;
      expect(primary, isNotNull);
      expect(primary!.hasFocus, isTrue);
      expect(focusedState, isTrue);
      expect(_readBufferRow(buffer, 0), startsWith('Focused Child'));

      final consumed = primary.bubbleKeyEvent(
        const KeyEvent('a', KeyType.character),
      );
      expect(consumed, isTrue);
      expect(handledEvent?.key, equals('a'));
    });

    test('Focus widget uses existing node', () async {
      final node = FocusNode(id: 'existing');
      final focusChanges = <bool>[];

      final focusWidget = Focus(
        focusNode: node,
        onFocusChange: focusChanges.add,
        child: const Text('Child'),
      );

      final element = focusWidget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 20)));
      await Future<void>.delayed(Duration.zero);
      final buffer = Buffer.blank(20, 20);
      element.paint(buffer, Offset.zero);

      expect(node.hasFocus, isFalse);

      node.requestFocus();
      expect(FocusManager.instance.primaryFocus, same(node));
      expect(node.hasFocus, isTrue);
      expect(focusChanges, equals([true]));
      expect(_readBufferRow(buffer, 0), startsWith('Child'));
    });

    test('FocusScope handles initialization', () async {
      final innerNode = FocusNode(id: 'inner');
      final focusScope = FocusScope(
        child: Focus(focusNode: innerNode, child: const Text('Inner')),
      );

      final element = focusScope.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 20)));
      final buffer = Buffer.blank(20, 20);
      element.paint(buffer, Offset.zero);

      expect(innerNode.parent, isA<FocusScopeNode>());
      final parentScope = innerNode.parent as FocusScopeNode;

      innerNode.requestFocus();
      expect(FocusManager.instance.primaryFocus, same(innerNode));
      expect(parentScope.focusedChild, same(innerNode));
      expect(_readBufferRow(buffer, 0), startsWith('Inner'));
    });
  });
}
