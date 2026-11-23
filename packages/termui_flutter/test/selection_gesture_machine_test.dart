import 'package:flutter_test/flutter_test.dart';
import 'package:termui/terminal/event.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart';
import 'package:termui_flutter/src/selection_gesture_machine.dart';

void main() {
  SelectionPointerDown down({
    required int col,
    required int row,
    int topVirtualRow = 0,
    Buffer? buffer,
    String? hoveredUri,
    bool builtinSelectionEnabled = true,
    bool builtinLinkOpenEnabled = true,
    bool mouseTracking = false,
    bool openVerticalScrollback = false,
    bool isShift = false,
    bool isAlt = false,
    bool isLinkModifier = false,
    bool isMacCtrlRightClick = false,
    DateTime? now,
  }) => (
    col: col,
    row: row,
    topVirtualRow: topVirtualRow,
    buffer: buffer,
    hoveredUri: hoveredUri,
    builtinSelectionEnabled: builtinSelectionEnabled,
    builtinLinkOpenEnabled: builtinLinkOpenEnabled,
    mouseTracking: mouseTracking,
    openVerticalScrollback: openVerticalScrollback,
    isShift: isShift,
    isAlt: isAlt,
    isLinkModifier: isLinkModifier,
    isMacCtrlRightClick: isMacCtrlRightClick,
    now: now ?? DateTime.utc(2026, 1, 1, 12),
  );

  SelectionPointerDrag drag({
    required int col,
    required int row,
    int? rawRow,
    int effRows = 10,
    int topVirtualRow = 0,
    Buffer? buffer,
    bool builtinSelectionEnabled = true,
    bool isAlt = false,
  }) => (
    col: col,
    row: row,
    rawRow: rawRow ?? row,
    effRows: effRows,
    topVirtualRow: topVirtualRow,
    buffer: buffer,
    builtinSelectionEnabled: builtinSelectionEnabled,
    isAlt: isAlt,
  );

  SelectionPointerUp up({
    required int col,
    required int row,
    String? hoveredUri,
    bool builtinSelectionEnabled = true,
    bool builtinLinkOpenEnabled = true,
    bool copyOnSelect = true,
    bool isLinkModifier = false,
  }) => (
    col: col,
    row: row,
    hoveredUri: hoveredUri,
    builtinSelectionEnabled: builtinSelectionEnabled,
    builtinLinkOpenEnabled: builtinLinkOpenEnabled,
    copyOnSelect: copyOnSelect,
    isLinkModifier: isLinkModifier,
  );

  group('SelectionGestureMachine', () {
    test('transitions pressing -> draggingStream <-> draggingBlock -> selected -> copyShortcut -> idle', () {
      final controller = TerminalSelectionController();
      var copies = 0;
      final openedUrls = <String>[];
      final machine = SelectionGestureMachine(
        controller: controller,
        onCopySelection: () {
          copies++;
          controller.clearSelection();
        },
        onOpenUrl: openedUrls.add,
      );
      addTearDown(() {
        machine.dispose();
        controller.dispose();
      });

      final buf = Buffer.blank(20, 10)
        ..writeString(0, 2, 'hello world', const Style());
      expect(machine.state, SelectionGestureState.idle);

      machine.dispatch(
        .leftDown,
        down(col: 1, row: 2, topVirtualRow: 10, buffer: buf),
      );
      expect(machine.state, SelectionGestureState.pressing);
      expect(machine.isSelectingGesture, isTrue);

      // Jitter on the initial tap cell stays in pressing without activating selection.
      machine.dispatch(
        .pointerDrag,
        drag(col: 1, row: 2, topVirtualRow: 10, buffer: buf),
      );
      expect(machine.state, SelectionGestureState.pressing);
      expect(controller.hasSelection, isFalse);

      // Dragging to col 5 enters draggingStream.
      machine.dispatch(
        .pointerDrag,
        drag(col: 5, row: 2, topVirtualRow: 10, buffer: buf),
      );
      expect(machine.state, SelectionGestureState.draggingStream);
      expect(controller.mode, SelectionMode.character);
      expect(controller.anchor, const SelectionPoint(1, 12));
      expect(controller.focus, const SelectionPoint(5, 12));

      // Pressing Alt mid-drag switches to draggingBlock; releasing Alt returns to draggingStream.
      machine.dispatch(
        .pointerDrag,
        drag(col: 6, row: 3, topVirtualRow: 10, buffer: buf, isAlt: true),
      );
      expect(machine.state, SelectionGestureState.draggingBlock);
      expect(controller.mode, SelectionMode.block);

      machine.dispatch(
        .pointerDrag,
        drag(col: 7, row: 3, topVirtualRow: 10, buffer: buf),
      );
      expect(machine.state, SelectionGestureState.draggingStream);
      expect(controller.mode, SelectionMode.character);

      // Releasing with copyOnSelect: false retains selection in `selected`.
      machine.dispatch(.leftUp, up(col: 7, row: 3, copyOnSelect: false));
      expect(machine.state, SelectionGestureState.selected);
      expect(machine.isSelectingGesture, isFalse);
      expect(copies, 0);
      expect(controller.hasSelection, isTrue);

      // Keyboard copyShortcut copies and returns to `idle`.
      machine.dispatch(.copyShortcut);
      expect(machine.state, SelectionGestureState.idle);
      expect(copies, 1);
      expect(controller.hasSelection, isFalse);
      expect(openedUrls, isEmpty);
    });

    test(
      'double-tap enters draggingWord and copyOnSelect release returns to idle',
      () {
        final controller = TerminalSelectionController();
        var copies = 0;
        final machine = SelectionGestureMachine(
          controller: controller,
          onCopySelection: () {
            copies++;
            controller.clearSelection();
          },
          onOpenUrl: (_) {},
        );
        addTearDown(() {
          machine.dispose();
          controller.dispose();
        });

        final buf = Buffer.blank(20, 6)
          ..writeString(0, 1, 'alpha beta gamma', const Style());
        final t0 = DateTime.utc(2026, 1, 1, 12);

        // First tap without drag clears selection and returns to idle.
        machine
          ..dispatch(
            .leftDown,
            down(col: 7, row: 1, topVirtualRow: 5, buffer: buf, now: t0),
          )
          ..dispatch(.leftUp, up(col: 7, row: 1));
        expect(machine.state, SelectionGestureState.idle);
        expect(controller.hasSelection, isFalse);

        // Second tap within doubleTapTimeout on the same virtual cell enters draggingWord.
        machine.dispatch(
          .leftDown,
          down(
            col: 7,
            row: 1,
            topVirtualRow: 5,
            buffer: buf,
            now: t0.add(const Duration(milliseconds: 120)),
          ),
        );
        expect(machine.state, SelectionGestureState.draggingWord);
        expect(controller.mode, SelectionMode.word);
        expect(controller.anchor, const SelectionPoint(6, 6));
        expect(controller.focus, const SelectionPoint(9, 6));

        // Dragging extends by whole words.
        machine.dispatch(
          .pointerDrag,
          drag(col: 13, row: 1, topVirtualRow: 5, buffer: buf),
        );
        expect(controller.focus, const SelectionPoint(15, 6));

        machine.dispatch(.leftUp, up(col: 13, row: 1));
        expect(machine.state, SelectionGestureState.idle);
        expect(copies, 1);
      },
    );

    test('routes mouseTracking to ptyTracking unless Shift is held, and emits synthetic release on cancel', () {
      final controller = TerminalSelectionController();
      final machine = SelectionGestureMachine(
        controller: controller,
        onCopySelection: controller.clearSelection,
        onOpenUrl: (_) {},
      );
      addTearDown(() {
        machine.dispose();
        controller.dispose();
      });

      final buf = Buffer.blank(20, 6)
        ..writeString(0, 0, 'tui row', const Style());

      // Unshifted press in mouseTracking enters ptyTracking without suppressing PTY mouse.
      machine.dispatch(
        .leftDown,
        down(col: 2, row: 0, buffer: buf, mouseTracking: true),
      );
      expect(machine.state, SelectionGestureState.ptyTracking);
      expect(
        machine.consumeLeftPtySuppression(term.MouseEventType.press),
        isFalse,
      );

      // PointerCancel from ptyTracking returns to idle and signals synthetic PTY release.
      machine.dispatch(.pointerCancel);
      expect(machine.state, SelectionGestureState.idle);
      expect(machine.consumeCancelPtyRelease(), isTrue);
      expect(machine.consumeCancelPtyRelease(), isFalse);

      // Shift+press in mouseTracking suppresses PTY mouse and starts local selection.
      machine.dispatch(
        .leftDown,
        down(col: 2, row: 0, buffer: buf, mouseTracking: true, isShift: true),
      );
      expect(machine.state, SelectionGestureState.pressing);
      expect(
        machine.consumeLeftPtySuppression(term.MouseEventType.press),
        isTrue,
      );
      expect(
        machine.consumeLeftPtySuppression(term.MouseEventType.release),
        isTrue,
      );
      expect(
        machine.consumeLeftPtySuppression(term.MouseEventType.press),
        isFalse,
      );
    });

    test('handles left and macOS right hyperlink clicks, drag disarming, and disarmLinks', () {
      final controller = TerminalSelectionController();
      final opened = <String>[];
      final machine = SelectionGestureMachine(
        controller: controller,
        onCopySelection: controller.clearSelection,
        onOpenUrl: opened.add,
      );
      addTearDown(() {
        machine.dispose();
        controller.dispose();
      });

      // 1. Stationary Ctrl+Click opens URL on release.
      machine
        ..dispatch(
          .leftDown,
          down(
            col: 3,
            row: 1,
            hoveredUri: 'https://dart.dev',
            isLinkModifier: true,
            mouseTracking: true,
          ),
        )
        ..dispatch(
          .leftUp,
          up(
            col: 3,
            row: 1,
            hoveredUri: 'https://dart.dev',
            isLinkModifier: true,
          ),
        );
      expect(machine.state, SelectionGestureState.idle);
      expect(opened, ['https://dart.dev']);

      // 2. Dragging off the pressed cell disarms link opening.
      machine
        ..dispatch(
          .leftDown,
          down(
            col: 3,
            row: 1,
            hoveredUri: 'https://flutter.dev',
            isLinkModifier: true,
          ),
        )
        ..dispatch(.pointerDrag, drag(col: 4, row: 1))
        ..dispatch(
          .leftUp,
          up(
            col: 4,
            row: 1,
            hoveredUri: 'https://flutter.dev',
            isLinkModifier: true,
          ),
        );
      expect(opened, ['https://dart.dev']);

      // 3. macOS Ctrl+RightClick suppresses PTY right mouse and opens on rightUp; disarmLinks cancels cleanly.
      machine.dispatch(
        .rightDown,
        down(
          col: 2,
          row: 0,
          hoveredUri: 'https://pub.dev',
          isMacCtrlRightClick: true,
        ),
      );
      expect(machine.state, SelectionGestureState.linkClicking);
      expect(
        machine.consumeRightLinkSuppression(
          term.MouseButton.right,
          term.MouseEventType.press,
        ),
        isTrue,
      );
      machine.disarmLinks();
      expect(machine.state, SelectionGestureState.idle);
    });

    testWidgets(
      'starts periodic edge auto-scroll when rawRow leaves viewport and stops on in-bounds drag or release',
      (tester) async {
        final controller = TerminalSelectionController();
        final ticks = <int>[];
        final machine = SelectionGestureMachine(
          controller: controller,
          onCopySelection: controller.clearSelection,
          onOpenUrl: (_) {},
          onEdgeAutoScroll: ticks.add,
          autoScrollInterval: const Duration(milliseconds: 50),
        );
        addTearDown(() {
          machine.dispose();
          controller.dispose();
        });

        final buf = Buffer.blank(20, 8)
          ..writeString(0, 4, 'line four', const Style());
        machine
          ..dispatch(.leftDown, down(col: 4, row: 4, buffer: buf))
          ..dispatch(
            .pointerDrag,
            drag(col: 2, row: 0, rawRow: -2, effRows: 8, buffer: buf),
          );
        expect(machine.state, SelectionGestureState.draggingStream);

        await tester.pump(const Duration(milliseconds: 160));
        expect(ticks, [-2, -2, -2]);

        // Returning inside the viewport stops the timer.
        machine.dispatch(
          .pointerDrag,
          drag(col: 2, row: 1, rawRow: 1, effRows: 8, buffer: buf),
        );
        ticks.clear();
        await tester.pump(const Duration(milliseconds: 120));
        expect(ticks, isEmpty);

        // Dragging below bottom starts positive auto-scroll, stopped on release.
        machine.dispatch(
          .pointerDrag,
          drag(col: 2, row: 7, rawRow: 10, effRows: 8, buffer: buf),
        );
        await tester.pump(const Duration(milliseconds: 110));
        expect(ticks, [3, 3]);

        machine.dispatch(.leftUp, up(col: 2, row: 7));
        expect(machine.state, SelectionGestureState.idle);
        ticks.clear();
        await tester.pump(const Duration(milliseconds: 120));
        expect(ticks, isEmpty);
      },
    );

    test('preserves PTY suppression across mid-press reset/disarmLinks and restarts cleanly on leftDown after missed leftUp', () {
      final controller = TerminalSelectionController();
      final machine = SelectionGestureMachine(
        controller: controller,
        onCopySelection: controller.clearSelection,
        onOpenUrl: (_) {},
      );
      addTearDown(() {
        machine.dispose();
        controller.dispose();
      });

      final buf = Buffer.blank(20, 6)
        ..writeString(0, 1, 'hello world', const Style());

      // M2: Shift+LeftDown in mouseTracking sets left PTY suppression; mid-press `.reset`
      // (e.g. altScreen switch / ESC[3J) must keep suppressing drag + release of that held press.
      machine.dispatch(
        .leftDown,
        down(col: 1, row: 1, buffer: buf, mouseTracking: true, isShift: true),
      );
      expect(
        machine.consumeLeftPtySuppression(term.MouseEventType.press),
        isTrue,
      );
      machine.dispatch(.reset);
      expect(machine.state, SelectionGestureState.idle);
      expect(
        machine.consumeLeftPtySuppression(term.MouseEventType.drag),
        isTrue,
      );
      expect(
        machine.consumeLeftPtySuppression(term.MouseEventType.release),
        isTrue,
      );
      expect(
        machine.consumeLeftPtySuppression(term.MouseEventType.press),
        isFalse,
      );

      // Same for macOS right-click link suppression across disarmLinks().
      machine.dispatch(
        .rightDown,
        down(
          col: 2,
          row: 0,
          hoveredUri: 'https://dart.dev',
          isMacCtrlRightClick: true,
        ),
      );
      expect(
        machine.consumeRightLinkSuppression(
          term.MouseButton.right,
          term.MouseEventType.press,
        ),
        isTrue,
      );
      machine.disarmLinks();
      expect(
        machine.consumeRightLinkSuppression(
          term.MouseButton.right,
          term.MouseEventType.release,
        ),
        isTrue,
      );

      // L1: If a leftUp is dropped while in draggingStream, the next leftDown restarts cleanly.
      machine
        ..dispatch(.leftDown, down(col: 1, row: 1, buffer: buf))
        ..dispatch(.pointerDrag, drag(col: 4, row: 1, buffer: buf));
      expect(machine.state, SelectionGestureState.draggingStream);

      machine.dispatch(.leftDown, down(col: 8, row: 3, buffer: buf));
      expect(machine.state, SelectionGestureState.pressing);
      expect(controller.anchor, const SelectionPoint(8, 3));
    });
  });
}
