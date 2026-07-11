import 'dart:math';
import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('Drag and Drop Widgets Tests', () {
    test('Draggable & DragTarget initialize correctly', () {
      const draggable = Draggable<String>(
        data: '🍎',
        child: SizedBox(width: 5, height: 5, child: Text('apple')),
      );

      final target = DragTarget<String>(
        onAccept: (item) {},
        builder: (context, candidate, rejected) {
          return SizedBox(width: 5, height: 5, child: Text(candidate.join()));
        },
      );

      expect(draggable.data, equals('🍎'));
      expect(draggable.getIntrinsicWidth(5), equals(5));
      expect(draggable.getIntrinsicHeight(5), equals(5));

      expect(target.getIntrinsicWidth(5), equals(5));
      expect(target.getIntrinsicHeight(5), equals(5));
    });

    test('Element recursive hitTest extension matches target coordinates', () {
      final root = SizedBox(
        width: 10,
        height: 10,
        child: Stack([
          Positioned(
            left: 2,
            top: 2,
            child: SizedBox(width: 4, height: 4, child: Text('box')),
          ),
        ]),
      );

      final rootElement = root.createElement()..mount(null);
      rootElement.layout(const BoxConstraints(minWidth: 10, minHeight: 10));

      // Coordinates: Point is 1-based SGR coordinate
      // Point(3, 3) -> 0-based cell (2, 2) which is inside Positioned child!
      final hits = rootElement.hitTest(const Point<int>(3, 3));
      expect(hits.length, greaterThan(1));

      final missed = rootElement.hitTest(const Point<int>(8, 8));
      expect(missed.length, equals(2));
    });

    test('DragSession updates and routes lifecycle hooks correctly', () {
      final accepted = <String>[];
      final target = DragTarget<String>(
        onAccept: (item) {
          accepted.add(item);
        },
        builder: (context, candidate, rejected) {
          return SizedBox(width: 10, height: 10, child: Text('target'));
        },
      );

      final targetElement = target.createElement() as DragTargetElement<String>;
      targetElement.mount(null);
      targetElement.layout(BoxConstraints.tight(const Size(10, 10)));

      final draggable = const Draggable<String>(
        data: '🍌',
        child: SizedBox(width: 5, height: 5, child: Text('source')),
      );
      final dragElement = draggable.createElement()..mount(null);
      dragElement.layout(BoxConstraints.tight(const Size(5, 5)));

      final session = DragSession(
        data: '🍌',
        sourceElement: dragElement,
        startMousePosition: const Point<int>(1, 1),
        currentMousePosition: const Point<int>(1, 1),
      );

      // Start drag
      DragDropManager.startDrag(session);
      expect(DragDropManager.activeSession, equals(session));

      // Enter target dropzone
      targetElement.handleDragEnter(session);
      expect(targetElement.childWidget, isNotNull);

      // Drop
      targetElement.handleDrop(session);
      expect(accepted.length, equals(1));
      expect(accepted.first, equals('🍌'));

      // Cancel/Reset drag
      DragDropManager.cancelDrag();
      expect(DragDropManager.activeSession, isNull);
    });

    test('Unregistering source/target cancels active drag session', () {
      final target = DragTarget<String>(
        onAccept: (item) {},
        builder: (context, candidate, rejected) =>
            const SizedBox(width: 10, height: 10),
      );
      final targetElement = target.createElement() as DragTargetElement<String>
        ..mount(null);
      targetElement.layout(BoxConstraints.tight(const Size(10, 10)));

      final draggable = const Draggable<String>(
        data: '🍉',
        child: SizedBox(width: 5, height: 5),
      );
      final dragElement = draggable.createElement()..mount(null);
      dragElement.layout(BoxConstraints.tight(const Size(5, 5)));

      final session = DragSession(
        data: '🍉',
        sourceElement: dragElement,
        startMousePosition: const Point<int>(1, 1),
        currentMousePosition: const Point<int>(1, 1),
      );

      DragDropManager.startDrag(session);
      DragDropManager.updateDrag(const Point<int>(1, 1));

      // Unmounting target should clear hovered target
      targetElement.unmount();
      expect(DragDropManager.activeSession, isNotNull);

      // Unmounting source element should cancel the active drag session entirely
      dragElement.unmount();
      expect(DragDropManager.activeSession, isNull);
    });
  });
}
