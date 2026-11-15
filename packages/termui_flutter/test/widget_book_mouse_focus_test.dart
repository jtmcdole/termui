import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/termui.dart' as termui;
import 'package:termui/terminal/terminal.dart' as term;
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/terminal.dart';
import 'package:termui_flutter/termui_flutter.dart';

double _relativeLuminance(int argb) {
  double linearize(int channel) {
    final srgb = channel / 255.0;
    return srgb <= 0.04045
        ? srgb / 12.92
        : math.pow((srgb + 0.055) / 1.055, 2.4).toDouble();
  }

  final r = linearize((argb >> 16) & 0xFF);
  final g = linearize((argb >> 8) & 0xFF);
  final b = linearize(argb & 0xFF);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _wcagContrastRatio(int firstArgb, int secondArgb) {
  final l1 = _relativeLuminance(firstArgb);
  final l2 = _relativeLuminance(secondArgb);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

Widget _testApp({required Widget home}) => WidgetsApp(
  color: const ui.Color(0xFF000000),
  pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
    settings: settings,
    pageBuilder: (context, _, _) => builder(context),
  ),
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Terminal forwards mouse clicks to FlutterTerminal when mouse tracking (?1000h/?1006h) is enabled',
    (tester) async {
      final selectionController = TerminalSelectionController();
      addTearDown(selectionController.dispose);

      late FlutterTerminal capturedTerminal;
      final buffer = termui.Buffer(40, 10);

      await tester.pumpWidget(
        _testApp(
          home: Terminal(
            selectionController: selectionController,
            fontSize: 14.0,
            onRun: (terminal, drawFrame) async {
              capturedTerminal = terminal;
              // Simulate PromptRunner enabling SGR mouse tracking (?1003h;?1006h).
              terminal.enableMouseTracking();
              drawFrame(buffer);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(capturedTerminal.mouseTracking, isTrue);

      final receivedMouse = <term.MouseEvent>[];
      final sub = capturedTerminal.events.listen((event) {
        if (event is term.MouseEvent) {
          receivedMouse.add(event);
        }
      });
      addTearDown(sub.cancel);

      final topLeft = tester.getTopLeft(find.byType(CustomPaint).last);
      final gesture = await tester.startGesture(
        topLeft + const Offset(5.0, 5.0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(topLeft + const Offset(150.0, 5.0));
      await tester.pump();

      expect(selectionController.isSelecting, isFalse);
      expect(selectionController.hasSelection, isFalse);

      await gesture.up();
      await tester.pump();

      expect(
        receivedMouse.any((e) => e.type == term.MouseEventType.press),
        isTrue,
      );
      expect(
        receivedMouse.any((e) => e.type == term.MouseEventType.drag),
        isTrue,
      );
    },
  );

  testWidgets(
    'PrivateTuiView forwards terminal.mouseTracking changes dynamically',
    (tester) async {
      final terminal = FlutterTerminal();
      addTearDown(terminal.dispose);
      final selectionController = TerminalSelectionController();
      addTearDown(selectionController.dispose);

      final receivedMouse = <term.MouseEvent>[];
      final sub = terminal.events.listen((event) {
        if (event is term.MouseEvent) {
          receivedMouse.add(event);
        }
      });
      addTearDown(sub.cancel);

      final buffer = termui.Buffer(40, 10);
      await tester.pumpWidget(
        _testApp(
          home: SizedBox(
            width: 400,
            height: 200,
            child: PrivateTuiView(
              terminal: terminal,
              selectionController: selectionController,
              service: const DefaultTerminalService(),
              fontSize: 14.0,
              fontFamily: 'Roboto Mono',
              onInit: (drawFrame) => drawFrame(buffer),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final topLeft = tester.getTopLeft(find.byType(CustomPaint).last);

      // Initially mouseTracking is false: drag creates local selection.
      expect(terminal.mouseTracking, isFalse);
      final selectGesture = await tester.startGesture(
        topLeft + const Offset(5.0, 5.0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await selectGesture.moveTo(topLeft + const Offset(100.0, 5.0));
      await tester.pump();
      expect(selectionController.isSelecting, isTrue);
      await selectGesture.up();
      await tester.pump();
      receivedMouse.clear();

      // Enable mouseTracking dynamically without rebuilding PrivateTuiView.
      terminal.enableMouseTracking();
      expect(terminal.mouseTracking, isTrue);

      final trackGesture = await tester.startGesture(
        topLeft + const Offset(5.0, 5.0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await trackGesture.moveTo(topLeft + const Offset(120.0, 5.0));
      await tester.pump();
      expect(selectionController.isSelecting, isFalse);
      expect(selectionController.hasSelection, isFalse);
      await trackGesture.up();
      await tester.pump();

      expect(
        receivedMouse.any((e) => e.type == term.MouseEventType.press),
        isTrue,
      );
      expect(
        receivedMouse.any((e) => e.type == term.MouseEventType.drag),
        isTrue,
      );
      expect(
        receivedMouse.any((e) => e.type == term.MouseEventType.release),
        isTrue,
      );

      // Disable mouseTracking dynamically: drag reverts to local selection.
      terminal.disableMouseTracking();
      expect(terminal.mouseTracking, isFalse);

      final postDisableGesture = await tester.startGesture(
        topLeft + const Offset(10.0, 5.0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await postDisableGesture.moveTo(topLeft + const Offset(110.0, 5.0));
      await tester.pump();
      expect(selectionController.isSelecting, isTrue);
      await postDisableGesture.up();
      await tester.pump();
    },
  );

  test(
    'TuiAtlasPainter focus cursor resolves WCAG AA glyph-to-cursor and cursor-to-canvas contrast without Modifier.reverse',
    () {
      const canvasBgArgb = 0xFF000000;
      final sodaArgb = termui.CharmColors.soda.argb;
      final charpleArgb = termui.CharmColors.charple.argb;
      final pepperArgb = termui.CharmColors.pepper.argb;

      final resolvedFg = TuiAtlasPainter.resolveCellForegroundArgb(
        sodaArgb,
        charpleArgb,
        modifiers: 0,
        isReverse: false,
      );
      final resolvedBg = TuiAtlasPainter.resolveCellBackgroundArgb(
        charpleArgb,
        sodaArgb,
        isReverse: false,
      );

      expect(resolvedFg, equals(sodaArgb));
      expect(resolvedBg, equals(charpleArgb));
      expect(
        _wcagContrastRatio(resolvedFg, resolvedBg),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _wcagContrastRatio(resolvedBg, canvasBgArgb),
        greaterThanOrEqualTo(3.0),
      );

      // Inverting dark pepper foreground onto the cursor background collapses
      // cursor-to-canvas contrast below WCAG 3.0:1.
      final reversedPepperBg = TuiAtlasPainter.resolveCellBackgroundArgb(
        charpleArgb,
        pepperArgb,
        isReverse: true,
      );
      final reversedPepperFg = TuiAtlasPainter.resolveCellForegroundArgb(
        pepperArgb,
        charpleArgb,
        modifiers: termui.Modifier.reverse,
        isReverse: true,
      );
      expect(reversedPepperBg, equals(pepperArgb));
      expect(reversedPepperFg, equals(charpleArgb));
      expect(_wcagContrastRatio(reversedPepperBg, canvasBgArgb), lessThan(3.0));
    },
  );
}
