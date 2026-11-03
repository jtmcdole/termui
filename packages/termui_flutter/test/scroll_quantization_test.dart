import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/termui.dart' as termui;
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  testWidgets(
    'ignores zero-dy horizontal swipes and quantizes fractional scroll deltas',
    (tester) async {
      final mouseEvents = <termui.MouseEvent>[];
      StreamSubscription<termui.InputEvent>? sub;
      addTearDown(() async => sub?.cancel());

      var now = DateTime(2026, 11, 2, 12);
      await withClock(Clock(() => now), () async {
        await tester.pumpWidget(
          MaterialApp(
            home: Terminal(
              onRun: (terminal, drawFrame) async {
                sub = terminal.events.listen((event) {
                  if (event is termui.MouseEvent) {
                    mouseEvents.add(event);
                  }
                });
                drawFrame(termui.Buffer(80, 24));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final center = tester.getCenter(find.byType(Terminal));

        // Pure horizontal trackpad swipe (dy == 0.0) must not emit wheelDown.
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(28.0, 0.0),
          ),
        );
        await tester.pump();
        expect(mouseEvents, isEmpty);

        // Two sub-cell micro-deltas (-6.0, -6.0 = -12.0) stay buffered;
        // third micro-delta (-8.0 = -20.0) crosses 1 cellHeight and emits 1 wheelUp.
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0.0, -6.0),
          ),
        );
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0.0, -6.0),
          ),
        );
        await tester.pump();
        expect(mouseEvents, isEmpty);

        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0.0, -8.0),
          ),
        );
        await tester.pump();
        expect(mouseEvents.length, equals(1));
        expect(mouseEvents.single.button, equals(termui.MouseButton.wheelUp));

        // Direction flip resets remainder immediately rather than fighting it.
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0.0, 20.0),
          ),
        );
        await tester.pump();
        expect(mouseEvents.length, equals(2));
        expect(mouseEvents.last.button, equals(termui.MouseButton.wheelDown));

        // Desktop trackpad PointerPanZoomUpdateEvent uses opposite panDelta sign.
        now = now.add(const Duration(seconds: 1));
        final panPointer = TestPointer(7, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(panPointer.panZoomStart(center));
        await tester.sendEventToBinding(
          panPointer.panZoomUpdate(center, pan: const Offset(0.0, 24.0)),
        );
        await tester.pump();
        expect(mouseEvents.length, equals(3));
        expect(mouseEvents.last.button, equals(termui.MouseButton.wheelUp));
      });
    },
  );

  testWidgets(
    'PointerPanZoomEndEvent and PointerCancelEvent clear sub-cell remainder immediately',
    (tester) async {
      final mouseEvents = <termui.MouseEvent>[];
      StreamSubscription<termui.InputEvent>? sub;
      addTearDown(() async => sub?.cancel());

      var now = DateTime(2026, 11, 2, 12);
      await withClock(Clock(() => now), () async {
        await tester.pumpWidget(
          MaterialApp(
            home: Terminal(
              onRun: (terminal, drawFrame) async {
                sub = terminal.events.listen((event) {
                  if (event is termui.MouseEvent &&
                      (event.button == termui.MouseButton.wheelUp ||
                          event.button == termui.MouseButton.wheelDown)) {
                    mouseEvents.add(event);
                  }
                });
                drawFrame(termui.Buffer(80, 24));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final center = tester.getCenter(find.byType(Terminal));

        // 1. Sub-cell panZoomUpdate (-10.0) followed by panZoomEnd must clear remainder
        // so a subsequent -10.0 delta within 20ms (< 250ms idle reset) stays sub-cell.
        final pan1 = TestPointer(11, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(pan1.panZoomStart(center));
        await tester.sendEventToBinding(
          pan1.panZoomUpdate(center, pan: const Offset(0.0, 10.0)),
        );
        await tester.sendEventToBinding(pan1.panZoomEnd());
        now = now.add(const Duration(milliseconds: 20));
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0.0, -10.0),
          ),
        );
        await tester.pump();
        expect(mouseEvents, isEmpty);

        // 2. Sub-cell remainder followed by PointerCancelEvent must also clear remainder
        // immediately before the next -10.0 delta arrives.
        now = now.add(const Duration(seconds: 1));
        final cancelPointer = TestPointer(12);
        await tester.sendEventToBinding(cancelPointer.down(center));
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0.0, -10.0),
          ),
        );
        await tester.sendEventToBinding(cancelPointer.cancel());
        now = now.add(const Duration(milliseconds: 20));
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0.0, -10.0),
          ),
        );
        await tester.pump();
        expect(mouseEvents, isEmpty);
      });
    },
  );
}
