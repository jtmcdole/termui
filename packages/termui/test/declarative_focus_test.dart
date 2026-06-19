import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/layout/column.dart';
import 'package:termui/ui/widgets/layout/sized_box.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/widget_toolkit.dart';

void main() {
  group('Declarative Focus Tree Tests', () {
    test('Focus nodes mount and parent automatically in widget tree', () {
      final rootScope = FocusScopeNode(id: 'root');
      final childNode1 = FocusNode(id: 'child1');
      final childNode2 = FocusNode(id: 'child2');

      final tree = ElementWidget(
        Focus(
          focusNode: rootScope,
          autofocus: true,
          child: Column([
            Focus(
              focusNode: childNode1,
              child: const SizedBox(width: 1, height: 1),
            ),
            Focus(
              focusNode: childNode2,
              child: const SizedBox(width: 1, height: 1),
            ),
          ]),
        ),
      );

      final buffer = Buffer.blank(10, 10);
      tree.layout(BoxConstraints.tight(const Size(10, 10)));
      tree.paint(buffer, Offset.zero);

      // Check parenting
      expect(childNode1.parent, equals(rootScope));
      expect(childNode2.parent, equals(rootScope));
      expect(rootScope.children, contains(childNode1));
      expect(rootScope.children, contains(childNode2));

      // Test requestFocus and propagation
      childNode1.requestFocus();
      expect(childNode1.isFocused, isTrue);
      expect(rootScope.isFocused, isTrue);
      expect(rootScope.focusedChild, equals(childNode1));

      // Test nextFocus
      rootScope.nextFocus();
      expect(childNode2.isFocused, isTrue);
      expect(childNode1.isFocused, isFalse);
      expect(rootScope.focusedChild, equals(childNode2));

      // Test previousFocus
      rootScope.previousFocus();
      expect(childNode1.isFocused, isTrue);
      expect(childNode2.isFocused, isFalse);
    });

    test('Key event bubbling up the focus tree', () {
      final rootScope = FocusScopeNode(id: 'root');
      final childNode = FocusNode(id: 'child');

      var rootReceived = false;
      var childReceived = false;

      rootScope.onKeyEvent = (event) {
        rootReceived = true;
        return true; // consume
      };

      childNode.onKeyEvent = (event) {
        childReceived = true;
        return false; // let bubble up
      };

      rootScope.addChild(childNode);
      childNode.requestFocus();

      final event = const KeyEvent('x', KeyType.character);
      final consumed = rootScope.bubbleKeyEvent(event);

      expect(consumed, isTrue);
      expect(childReceived, isTrue);
      expect(rootReceived, isTrue);
    });
  });
}
