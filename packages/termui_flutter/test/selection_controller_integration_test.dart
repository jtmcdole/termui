import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/termui.dart' as termui;
import 'package:termui_flutter/src/rendering/painter.dart';
import 'package:termui_flutter/src/terminal.dart' show PrivateTuiView;
import 'package:termui_flutter/termui_flutter.dart';

Widget _testApp({required Widget home}) => WidgetsApp(
  color: const ui.Color(0xFF000000),
  pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
    settings: settings,
    pageBuilder: (context, _, _) => builder(context),
  ),
  home: home,
);

Uint8List _pngIhdrHeader(int width, int height) {
  final header = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(const [0x00, 0x00, 0x00, 0x0D])
    ..add(const [0x49, 0x48, 0x44, 0x52]);
  final dims = ByteData(8)
    ..setUint32(0, width)
    ..setUint32(4, height);
  header
    ..add(dims.buffer.asUint8List())
    ..add(const [0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
  return header.toBytes();
}

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
          _testApp(
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
        _testApp(
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
        _testApp(
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
          _testApp(
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
          _testApp(
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

    testWidgets(
      'enableBuiltinSelection: false and enableBuiltinLinkOpen: false delegate pointer handling to host',
      (tester) async {
        final buffer = termui.Buffer(40, 10);
        buffer.writeString(0, 0, 'Delegated Link Text', const termui.Style());
        for (var x = 0; x < 19; x++) {
          buffer.setUri(x, 0, 'https://example.com/delegated');
        }

        final terminal = FlutterTerminal();
        addTearDown(terminal.dispose);
        final injectedEvents = <termui.MouseEvent>[];
        final sub = terminal.events.listen((event) {
          if (event is termui.MouseEvent) {
            injectedEvents.add(event);
          }
        });
        addTearDown(sub.cancel);

        await tester.pumpWidget(
          _testApp(
            home: Terminal(
              terminal: terminal,
              service: service,
              selectionController: selectionController,
              enableBuiltinSelection: false,
              enableBuiltinLinkOpen: false,
              fontSize: 14.0,
              onRun: (_, drawFrame) async {
                drawFrame(buffer);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final customPaintFinder = find.byType(CustomPaint).last;
        final topLeft = tester.getTopLeft(customPaintFinder);
        final p1 = topLeft + const Offset(10.0, 5.0);
        final p2 = topLeft + const Offset(120.0, 5.0);

        // Dragging does not activate built-in selection or copy to clipboard.
        final drag = await tester.startGesture(
          p1,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await drag.moveTo(p2);
        await tester.pump();
        await drag.up();
        await tester.pump();

        expect(selectionController.isSelecting, isFalse);
        expect(selectionController.hasSelection, isFalse);
        expect(service.clipboardText, isNull);
        expect(injectedEvents, isNotEmpty);

        // Ctrl+Click does not open URL via built-in handler.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        final click = await tester.startGesture(
          p1,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await click.up();
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(service.openedUrl, isNull);
      },
    );

    testWidgets(
      'runtime setEnableBuiltinSelection/LinkOpen, exactCellPixelSize, paste KeyUpEvent suppression, and PNG IHDR guard work end-to-end',
      (tester) async {
        final buffer = termui.Buffer(40, 10);
        buffer.writeString(0, 0, 'Runtime Link Text', const termui.Style());
        for (var x = 0; x < 17; x++) {
          buffer.setUri(x, 0, 'https://example.com/runtime');
        }

        // Register a mismatched/oversized PNG (pixelWidth=2, IHDR=20000x20000) to verify decode guard.
        final registry = termui.KittyImageRegistry();
        final bombData = termui.KittyImageData.fromPng(
          imageId: 99,
          pixelWidth: 2,
          pixelHeight: 2,
          pngBytes: _pngIhdrHeader(20000, 20000),
          gridCols: 1,
          gridRows: 1,
        );
        registry.registerImage(bombData);
        buffer
          ..registerKittyRegistry(const termui.Rect(0, 0, 40, 10), registry)
          ..setAttributes(
            0,
            2,
            char: termui.kittyPlaceholderCell(0, 0),
            fg: 0xFF000063,
            bg: 0xFF000000,
            modifiers: termui.Modifier.kittyPlaceholder,
          );

        final terminal = FlutterTerminal();
        addTearDown(terminal.dispose);
        final exactEmissions = <(double, double)>[];
        final exactSub = terminal.watchExactCellPixelSize().listen(
          exactEmissions.add,
        );
        addTearDown(exactSub.cancel);
        final keyEvents = <termui.KeyEvent>[];
        final eventSub = terminal.events.listen((event) {
          if (event is termui.KeyEvent) keyEvents.add(event);
        });
        addTearDown(eventSub.cancel);

        service.clipboardText = 'pasted';
        await tester.pumpWidget(
          _testApp(
            home: Terminal(
              terminal: terminal,
              service: service,
              selectionController: selectionController,
              fontSize: 13.5,
              onRun: (_, drawFrame) async {
                drawFrame(buffer);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. exactCellPixelSize reports finite > 0 metrics alongside rounded cellPixelSize.
        expect(terminal.exactCellPixelSize.$1, greaterThan(0.0));
        expect(terminal.exactCellPixelSize.$2, greaterThan(0.0));
        expect(
          terminal.cellPixelSize,
          equals((
            terminal.exactCellPixelSize.$1.round(),
            terminal.exactCellPixelSize.$2.round(),
          )),
        );
        terminal.setFontSize(17.25);
        await tester.pumpAndSettle();
        expect(exactEmissions, isNotEmpty);

        // 2. Mismatched/oversized PNG IHDR is rejected before instantiateImageCodec allocates GPU texture.
        final paintWidget = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(PrivateTuiView),
            matching: find.byType(CustomPaint),
          ),
        );
        final painter = paintWidget.painter! as TuiAtlasPainter;
        expect(painter.kittyImages.containsKey(bombData), isFalse);

        // 3. Runtime setEnableBuiltinSelection(false) clears active selection and stops auto-copy.
        selectionController
          ..startSelection(0, 0)
          ..updateSelection(5, 0);
        expect(selectionController.hasSelection, isTrue);
        service.clipboardText = null;
        terminal
          ..setEnableBuiltinSelection(false)
          ..setEnableBuiltinLinkOpen(false);
        await tester.pump();
        expect(selectionController.hasSelection, isFalse);

        final topLeft = tester.getTopLeft(find.byType(CustomPaint).last);
        final drag = await tester.startGesture(
          topLeft + const Offset(10.0, 5.0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await drag.moveTo(topLeft + const Offset(90.0, 5.0));
        await tester.pump();
        await drag.up();
        await tester.pump();
        expect(selectionController.hasSelection, isFalse);
        expect(service.clipboardText, isNull);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        final click = await tester.startGesture(
          topLeft + const Offset(10.0, 5.0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await click.up();
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(service.openedUrl, isNull);

        // 4. Host paste shortcut (Cmd+V) suppresses orphan KeyUpEvent for 'v' when reportKeyReleaseEvents is enabled.
        service.clipboardText = 'clip';
        terminal.setReportKeyReleaseEvents(true);
        keyEvents.clear();
        final focusFinder = find.descendant(
          of: find.byType(PrivateTuiView),
          matching: find.byType(Focus),
        );
        tester.widget<Focus>(focusFinder).focusNode?.requestFocus();
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();

        expect(
          keyEvents.where((e) => e.key == 'v' || e.baseKey == 'v'),
          isEmpty,
        );
      },
    );

    testWidgets(
      'procedural box and block glyphs register all style variants without missing-glyph atlas re-bakes',
      (tester) async {
        final atlas = await tester.runAsync(
          () => GlyphAtlasGenerator.generate(
            fontSize: 13.0,
            fontFamily: 'Cascadia Mono',
          ),
        );
        addTearDown(() => atlas?.dispose());

        for (final ch in const ['─', '│', '┌', '┐', '═', '║', '█', '░']) {
          expect(
            atlas!.hasNativeVariant(ch, GlyphStyleVariant.bold),
            isTrue,
            reason: 'Expected procedural "$ch" to alias bold without re-bake',
          );
          expect(
            atlas.hasNativeVariant(ch, GlyphStyleVariant.boldItalic),
            isTrue,
          );
        }

        final buf = termui.Buffer(12, 4);
        buf.writeString(
          0,
          0,
          '┌──┐══██░░',
          const termui.Style(modifiers: termui.Modifier.bold),
        );
        final missingStyled = <(String, GlyphStyleVariant)>[];
        final painter = TuiAtlasPainter(
          buffer: buf,
          atlas: atlas!,
          fontFamily: 'Cascadia Mono',
          fallbackPainters: {},
          onMissingGlyphs: null,
          onMissingStyledGlyphs: missingStyled.addAll,
        );
        final rec = ui.PictureRecorder();
        painter.paint(Canvas(rec), const Size(200, 80));
        rec.endRecording().dispose();
        await tester.pump();

        expect(missingStyled, isEmpty);
      },
    );
  });
}
