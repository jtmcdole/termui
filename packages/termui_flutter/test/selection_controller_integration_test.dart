import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/termui.dart' as termui;
import 'package:termui_flutter/src/service/terminal_service.dart';
import 'package:termui_flutter/termui_flutter.dart';

class FakeTerminalService implements TerminalService {
  String? clipboardText;
  String? openedUrl;

  @override
  Future<void> setClipboard(String text) async {
    clipboardText = text;
  }

  @override
  Future<String?> getClipboard() async => clipboardText;

  @override
  Future<bool> openUrl(String url) async {
    openedUrl = url;
    return true;
  }

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) async =>
      basename;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Selection Controller Integration Tests', () {
    late FakeTerminalService service;
    late TerminalSelectionController selectionController;

    setUp(() {
      service = FakeTerminalService();
      selectionController = TerminalSelectionController();
    });

    tearDown(() {
      selectionController.dispose();
    });

    testWidgets(
      'normal left drag performs stream selection and copies on pointer release',
      (tester) async {
        final buffer = termui.Buffer(40, 10);
        buffer.writeString(0, 0, 'First Line of Text', const termui.Style());
        buffer.writeString(0, 1, 'Second Line of Text', const termui.Style());

        await tester.pumpWidget(
          MaterialApp(
            home: Terminal(
              service: service,
              selectionController: selectionController,
              fontSize: 14.0,
              onRun: (terminal, drawFrame) async {
                drawFrame(buffer);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final customPaintFinder = find.byType(CustomPaint).last;
        final topLeft = tester.getTopLeft(customPaintFinder);

        // Cell width and height in test font
        // Pointer down at cell (0, 0)
        final p1 = topLeft + const Offset(5.0, 5.0);
        // Pointer move to cell (10, 0)
        final p2 = topLeft + const Offset(150.0, 5.0);

        final gesture = await tester.startGesture(
          p1,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        expect(selectionController.isSelecting, isTrue);

        await gesture.moveTo(p2);
        await tester.pump();

        expect(selectionController.hasSelection, isTrue);
        expect(selectionController.mode, equals(SelectionMode.stream));
        expect(selectionController.isCellSelected(0, 0), isTrue);

        await gesture.up();
        await tester.pump();

        expect(service.clipboardText, isNotNull);
        expect(service.clipboardText, startsWith('First'));
      },
    );

    testWidgets('Alt + drag performs rectangular block selection', (
      tester,
    ) async {
      final buffer = termui.Buffer(40, 10);
      buffer.writeString(0, 0, 'AAAA BBBB CCCC', const termui.Style());
      buffer.writeString(0, 1, 'DDDD EEEE FFFF', const termui.Style());
      buffer.writeString(0, 2, 'GGGG HHHH IIII', const termui.Style());

      await tester.pumpWidget(
        MaterialApp(
          home: Terminal(
            service: service,
            selectionController: selectionController,
            fontSize: 14.0,
            onRun: (terminal, drawFrame) async {
              drawFrame(buffer);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final customPaintFinder = find.byType(CustomPaint).last;
      final topLeft = tester.getTopLeft(customPaintFinder);

      // Simulate Alt/Option key down
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      final p1 = topLeft + const Offset(5.0, 5.0);
      final p2 = topLeft + const Offset(35.0, 35.0);

      final gesture = await tester.startGesture(
        p1,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(p2);
      await tester.pump();

      expect(selectionController.mode, equals(SelectionMode.block));
      expect(selectionController.hasSelection, isTrue);

      await gesture.up();
      await tester.pump();

      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      expect(service.clipboardText, isNotNull);
    });

    testWidgets('extracts and copies hidden characters on pointer release', (
      tester,
    ) async {
      final buffer = termui.Buffer(40, 10);
      buffer.writeString(0, 0, 'PIN: 9876', const termui.Style());
      // Apply Modifier.hidden to '9876' (cols 5..8)
      for (var x = 5; x <= 8; x++) {
        buffer.setModifiers(x, 0, termui.Modifier.hidden);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Terminal(
            service: service,
            selectionController: selectionController,
            fontSize: 14.0,
            onRun: (terminal, drawFrame) async {
              drawFrame(buffer);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final customPaintFinder = find.byType(CustomPaint).last;
      final topLeft = tester.getTopLeft(customPaintFinder);

      final p1 = topLeft + const Offset(5.0, 5.0);
      final p2 = topLeft + const Offset(150.0, 5.0);

      final gesture = await tester.startGesture(
        p1,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(p2);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(service.clipboardText, contains('9876'));
    });

    testWidgets(
      'clicking link without Ctrl does NOT open URL; Ctrl+Click opens URL',
      (tester) async {
        final buffer = termui.Buffer(40, 10);
        buffer.writeString(0, 0, 'Docs: Click Here', const termui.Style());
        for (var x = 0; x < 20; x++) {
          buffer.setUri(x, 0, 'https://example.com/docs');
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Terminal(
              service: service,
              selectionController: selectionController,
              fontSize: 14.0,
              onRun: (terminal, drawFrame) async {
                drawFrame(buffer);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final customPaintFinder = find.byType(CustomPaint).last;
        final topLeft = tester.getTopLeft(customPaintFinder);

        // Cell on row 0
        final linkPos = topLeft + const Offset(50.0, 5.0);

        // 1. Plain click without Ctrl
        final gesture1 = await tester.startGesture(
          linkPos,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await gesture1.up();
        await tester.pump();

        expect(service.openedUrl, isNull);

        // 2. Control + click
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        final gesture2 = await tester.startGesture(
          linkPos,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await gesture2.up();
        await tester.pump();

        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(service.openedUrl, equals('https://example.com/docs'));
      },
    );

    testWidgets(
      'confines selection to split pane region when dividers are present',
      (tester) async {
        final buffer = termui.Buffer(40, 10);
        // Create vertical split at col 15 with divider '│'
        for (var y = 0; y < 10; y++) {
          buffer.writeString(0, y, 'Left Pane Content', const termui.Style());
          buffer.setCharacter(15, y, '│');
          buffer.writeString(16, y, 'Right Pane Area', const termui.Style());
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Terminal(
              service: service,
              selectionController: selectionController,
              fontSize: 14.0,
              onRun: (terminal, drawFrame) async {
                drawFrame(buffer);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final customPaintFinder = find.byType(CustomPaint).last;
        final topLeft = tester.getTopLeft(customPaintFinder);

        // Start drag inside left pane (col 2, row 1)
        final p1 = topLeft + const Offset(20.0, 20.0);
        // Drag past the vertical divider to right pane area (col 25, row 3)
        final p2 = topLeft + const Offset(200.0, 45.0);

        final gesture = await tester.startGesture(
          p1,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await gesture.moveTo(p2);
        await tester.pump();

        // The selection region must be bounded to the left pane (maxCol 14)
        expect(selectionController.region, isNotNull);
        expect(selectionController.region!.maxCol, equals(14));

        // Right pane cells must NOT be selected!
        expect(selectionController.isCellSelected(15, 2), isFalse);
        expect(selectionController.isCellSelected(20, 2), isFalse);

        await gesture.up();
        await tester.pump();

        // Extracted text should only contain left pane text
        expect(service.clipboardText, isNotNull);
        expect(service.clipboardText, isNot(contains('Right Pane')));
      },
    );
  });
}
