import 'package:termui/termui.dart';
import 'package:test/test.dart';

String _rowText(Buffer buffer, int y) =>
    [for (var x = 0; x < buffer.width; x++) buffer.getCharacter(x, y)].join();

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('ModalOverlayElement paint and focus', () {
    test('performPaint handles compact dialogBounds Rect(2, 2, 1, 3)', () {
      final buffer = Buffer.blank(10, 8);
      const borderStyle = Style(
        foreground: Color(255, 255, 255),
        background: Color(10, 20, 30),
      );
      final modal = ModalOverlay(
        title: 'Compact',
        width: 10,
        height: 8,
        dialogBounds: const Rect(2, 2, 1, 3),
        borderStyle: borderStyle,
        modalFocusNodes: const [],
        child: const Text('Hidden'),
      );
      final el = modal.createElement()..mount(null);
      el.layout(BoxConstraints.tight(const Size(10, 8)));
      el.paint(buffer, Offset.zero);

      for (var y = 2; y < 5; y++) {
        expect(buffer.getCharacter(2, y), ' ');
        expect(buffer.getBackground(2, y), borderStyle.background?.argb);
        expect(buffer.getModifiers(2, y) & Modifier.dim, 0);
      }
      expect(buffer.getModifiers(0, 0) & Modifier.dim, isNonZero);
    });

    test(
      'performPaint focuses first unfocused node and preserves an already focused second node',
      () {
        final node1 = FocusNode(id: 'node1');
        final node2 = FocusNode(id: 'node2');
        addTearDown(() {
          node1.dispose();
          node2.dispose();
        });

        final modal = ModalOverlay(
          title: 'Focus',
          width: 20,
          height: 10,
          dialogBounds: const Rect(2, 2, 16, 6),
          modalFocusNodes: [node1, node2],
          child: const SizedBox.shrink(),
        );
        final el = modal.createElement()..mount(null);
        el.layout(BoxConstraints.tight(const Size(20, 10)));

        // Unfocus all modal nodes, then paint: first node should regain focus.
        FocusManager.instance.setPrimaryFocus(null);
        expect(node1.isFocused, isFalse);
        expect(node2.isFocused, isFalse);

        final buffer = Buffer.blank(20, 10);
        el.paint(buffer, Offset.zero);
        expect(node1.isFocused, isTrue);
        expect(node2.isFocused, isFalse);

        // Focus second node, then paint again: second node should keep focus.
        node2.requestFocus();
        expect(node2.isFocused, isTrue);
        el.paint(buffer, Offset.zero);
        expect(node2.isFocused, isTrue);
        expect(node1.isFocused, isFalse);
      },
    );

    test(
      'long title truncates with ... at dw = 12 and is suppressed at dw = 7',
      () {
        const longTitle = 'Very Long Dialog Title';

        final truncatedBuffer = Buffer.blank(20, 8);
        final truncatedModal = ModalOverlay(
          title: longTitle,
          width: 20,
          height: 8,
          dialogBounds: const Rect(2, 1, 12, 5),
          modalFocusNodes: const [],
          child: const SizedBox.shrink(),
        );
        final truncatedEl = truncatedModal.createElement()..mount(null);
        truncatedEl.layout(BoxConstraints.tight(const Size(20, 8)));
        truncatedEl.paint(truncatedBuffer, Offset.zero);

        final truncatedRow = _rowText(truncatedBuffer, 1).substring(2, 14);
        expect(truncatedRow, '┌ Very ... ┐');
        expect(truncatedModal.isPositionOnTitle(3, 1), isTrue);
        expect(truncatedModal.isPositionOnTitle(12, 1), isTrue);
        expect(truncatedModal.isPositionOnTitle(2, 1), isFalse);

        final suppressedBuffer = Buffer.blank(20, 8);
        final suppressedModal = ModalOverlay(
          title: longTitle,
          width: 20,
          height: 8,
          dialogBounds: const Rect(2, 1, 7, 5),
          modalFocusNodes: const [],
          child: const SizedBox.shrink(),
        );
        final suppressedEl = suppressedModal.createElement()..mount(null);
        suppressedEl.layout(BoxConstraints.tight(const Size(20, 8)));
        suppressedEl.paint(suppressedBuffer, Offset.zero);

        final suppressedRow = _rowText(suppressedBuffer, 1).substring(2, 9);
        expect(suppressedRow, '┌─────┐');
        expect(suppressedModal.isPositionOnTitle(4, 1), isFalse);
      },
    );
  });
}
