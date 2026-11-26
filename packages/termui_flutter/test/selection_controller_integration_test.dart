import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
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

    testWidgets(
      'double-click selects hit word, clears selection after copy on release, and double-click-drag extends by whole words',
      (tester) async {
        final buffer = termui.Buffer(40, 6);
        buffer.writeString(
          0,
          0,
          'hello world_42 foo.bar',
          const termui.Style(),
        );
        final atlasCtrl = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Cascadia Mono',
        );
        addTearDown(atlasCtrl.dispose);
        await tester.runAsync(atlasCtrl.ensureInitialized);

        await tester.pumpWidget(
          _testApp(
            home: TerminalSurface(
              atlasController: atlasCtrl,
              service: service,
              selectionController: selectionController,
              buffer: buffer,
              fontSize: 14.0,
              alignment: Alignment.topLeft,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final atlas = atlasCtrl.atlas!;
        final paintFinder = find.descendant(
          of: find.byType(TerminalSurface),
          matching: find.byType(CustomPaint),
        );
        final topLeft = tester.getTopLeft(paintFinder);

        Future<TestGesture> tapAt(Offset p, {bool release = true}) async {
          final g = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
          await tester.pump(const Duration(milliseconds: 20));
          if (release) {
            await g.up();
            await tester.pump(const Duration(milliseconds: 40));
          }
          return g;
        }

        // Double-click on 'world_42' (col 8, row 0).
        final wordHit =
            topLeft + Offset(atlas.cellWidth * 8.5, atlas.cellHeight * 0.5);
        await tapAt(wordHit);
        final g2 = await tapAt(wordHit, release: false);

        expect(selectionController.hasSelection, isTrue);
        expect(selectionController.mode, equals(SelectionMode.word));
        expect(selectionController.extractText(buffer), equals('world_42'));

        await g2.up();
        await tester.pump(const Duration(milliseconds: 40));
        expect(service.clipboardText, equals('world_42'));
        expect(selectionController.hasSelection, isFalse);

        // Double-click 'hello' (col 2) and drag to 'world_42' (col 9) -> snaps both words.
        await tester.pump(const Duration(milliseconds: 600));
        final helloHit =
            topLeft + Offset(atlas.cellWidth * 2.5, atlas.cellHeight * 0.5);
        await tapAt(helloHit);
        final d2 = await tapAt(helloHit, release: false);
        await d2.moveTo(wordHit);
        await tester.pump(const Duration(milliseconds: 20));
        expect(
          selectionController.extractText(buffer),
          equals('hello world_42'),
        );

        await d2.up();
        await tester.pump();
        expect(service.clipboardText, equals('hello world_42'));
        expect(selectionController.hasSelection, isFalse);
      },
    );

    testWidgets(
      'mouseTracking Shift latch, PointerCancelEvent, copyOnSelect: false, and CJK double-click',
      (tester) async {
        final buffer = termui.Buffer(40, 6)
          ..writeString(0, 0, '日本語 hello', const termui.Style());
        final atlasCtrl = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Cascadia Mono',
        );
        addTearDown(atlasCtrl.dispose);
        await tester.runAsync(atlasCtrl.ensureInitialized);
        final injected = <termui.MouseEvent>[];
        var mouseTracking = true;
        var copyOnSelect = true;
        Future<Offset> pump(bool builtinSel) async {
          await tester.pumpWidget(
            _testApp(
              home: TerminalSurface(
                atlasController: atlasCtrl,
                service: service,
                selectionController: selectionController,
                buffer: buffer,
                mouseTrackingProvider: () => mouseTracking,
                copyOnSelectProvider: () => copyOnSelect,
                enableBuiltinSelection: builtinSel,
                alignment: Alignment.topLeft,
                onInputEvent: (e) {
                  if (e is termui.MouseEvent) injected.add(e);
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          return tester.getTopLeft(
            find.descendant(
              of: find.byType(TerminalSurface),
              matching: find.byType(CustomPaint),
            ),
          );
        }

        final atlas = atlasCtrl.atlas!;
        final topLeft = await pump(true);
        Offset cell(double c) =>
            topLeft + Offset(atlas.cellWidth * c, atlas.cellHeight * 0.5);
        Future<TestGesture> down(double c) =>
            tester.startGesture(cell(c), kind: PointerDeviceKind.mouse);
        Future<void> click(double c, {bool jitter = true}) async {
          final g = await down(c);
          await tester.pump(const Duration(milliseconds: 20));
          if (jitter) await g.moveBy(const Offset(0.2, 0.1));
          await g.up();
          await tester.pump(const Duration(milliseconds: 20));
        }

        const pressRelease = [
          termui.MouseEventType.press,
          termui.MouseEventType.release,
        ];

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        final drag = await down(7.5);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await drag.moveTo(cell(11.5));
        await tester.pump();
        expect(selectionController.extractText(buffer), equals('hello'));
        await drag.up();
        await tester.pump();
        expect(injected, isEmpty);
        expect(service.clipboardText, equals('hello'));
        expect(selectionController.hasSelection, isFalse);

        final ptyGesture = await down(7.5);
        await tester.pump();
        await ptyGesture.cancel();
        await tester.pump();
        expect(injected.map((e) => e.type), equals(pressRelease));

        injected.clear();
        await pump(false);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await click(7.5, jitter: false);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(injected.map((e) => e.type), equals(pressRelease));

        buffer.setUri(7, 0, 'https://example.com');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await click(7.5);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(service.openedUrl, equals('https://example.com'));

        service.clipboardText = null;
        mouseTracking = false;
        copyOnSelect = false;
        await pump(true);
        await click(2.5);
        await click(3.5);
        expect(selectionController.hasSelection, isTrue);
        expect(selectionController.mode, equals(SelectionMode.word));
        expect(selectionController.extractText(buffer), equals('日本語'));
        expect(service.clipboardText, isNull);

        for (final cancel in [false, true]) {
          final rg = await tester.startGesture(
            cell(7.5),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await (cancel ? rg.cancel() : rg.up());
        }
        await tester.pump();
        expect(selectionController.hasSelection, isTrue);
      },
    );

    testWidgets(
      'clears selection highlight pixels after auto-copy and after keyboard copy when copyOnSelect is false',
      (tester) async {
        final buffer = termui.Buffer(30, 4)
          ..writeString(0, 0, 'Copy Me Now', const termui.Style());
        final atlasCtrl = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Cascadia Mono',
        );
        addTearDown(atlasCtrl.dispose);
        await tester.runAsync(atlasCtrl.ensureInitialized);

        final keyEvents = <termui.KeyEvent>[];
        var copyOnSelect = true;
        await tester.pumpWidget(
          _testApp(
            home: TerminalSurface(
              atlasController: atlasCtrl,
              service: service,
              selectionController: selectionController,
              buffer: buffer,
              copyOnSelectProvider: () => copyOnSelect,
              reportKeyReleaseEvents: true,
              alignment: Alignment.topLeft,
              onInputEvent: (e) {
                if (e is termui.KeyEvent) keyEvents.add(e);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final atlas = atlasCtrl.atlas!;
        final surfaceFinder = find.byType(TerminalSurface);
        final topLeft = tester.getTopLeft(
          find.descendant(
            of: surfaceFinder,
            matching: find.byType(CustomPaint),
          ),
        );
        Offset cellCenter(double col) =>
            topLeft + Offset(atlas.cellWidth * col, atlas.cellHeight * 0.5);

        Future<(int, int, int)> sampleSpaceCellRgb() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find
                .descendant(
                  of: surfaceFinder,
                  matching: find.byType(RepaintBoundary),
                )
                .first,
          );
          final img = await tester.runAsync(
            () => boundary.toImage(pixelRatio: 1.0),
          );
          addTearDown(() => img?.dispose());
          final bytes = await tester.runAsync(
            () => img!.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          final sx = ((4 + 0.5) * atlas.cellWidth).floor();
          final sy = (0.5 * atlas.cellHeight).floor();
          final idx = (sy * img!.width + sx) * 4;
          return (
            bytes!.getUint8(idx),
            bytes.getUint8(idx + 1),
            bytes.getUint8(idx + 2),
          );
        }

        const selBg = (0x26, 0x4F, 0x78);
        const canvasBg = (0x00, 0x00, 0x00);

        // 1. copyOnSelect: true -> highlight shows during drag, disappears after release & copy.
        final drag1 = await tester.startGesture(
          cellCenter(0.5),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await drag1.moveTo(cellCenter(6.5));
        await tester.pump();
        expect(selectionController.hasSelection, isTrue);
        expect(await sampleSpaceCellRgb(), equals(selBg));

        await drag1.up();
        await tester.pump();
        expect(service.clipboardText, equals('Copy Me'));
        expect(selectionController.hasSelection, isFalse);
        expect(await sampleSpaceCellRgb(), equals(canvasBg));

        // 2. copyOnSelect: false -> highlight stays on release, then disappears on Cmd+C, Ctrl+Shift+C, and Ctrl+Insert.
        copyOnSelect = false;
        final shortcuts = <List<LogicalKeyboardKey>>[
          [
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.shiftLeft,
            LogicalKeyboardKey.keyC,
          ],
          [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyC],
          [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.insert],
        ];
        for (final chord in shortcuts) {
          service.clipboardText = null;
          keyEvents.clear();

          final drag = await tester.startGesture(
            cellCenter(0.5),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await drag.moveTo(cellCenter(6.5));
          await tester.pump();
          await drag.up();
          await tester.pump();

          expect(service.clipboardText, isNull);
          expect(selectionController.hasSelection, isTrue);
          expect(await sampleSpaceCellRgb(), equals(selBg));

          for (final k in chord) {
            await tester.sendKeyDownEvent(k);
          }
          await tester.pump();
          for (final k in chord.reversed) {
            await tester.sendKeyUpEvent(k);
          }
          await tester.pump();

          expect(service.clipboardText, equals('Copy Me'));
          expect(selectionController.hasSelection, isFalse);
          expect(await sampleSpaceCellRgb(), equals(canvasBg));
          expect(keyEvents, isEmpty);
        }

        // 3. Without active selection, Ctrl+Shift+C still forwards to onInputEvent.
        keyEvents.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(keyEvents.where((e) => e.key == 'c'), isNotEmpty);
      },
    );

    testWidgets(
      'holding a copy shortcut into key repeat does not leak KeyRepeatEvents after KeyDownEvent clears selection',
      (tester) async {
        final buffer = termui.Buffer(30, 4)
          ..writeString(0, 0, 'Copy Me Now', const termui.Style());
        final atlasCtrl = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Cascadia Mono',
        );
        addTearDown(atlasCtrl.dispose);
        await tester.runAsync(atlasCtrl.ensureInitialized);

        final keyEvents = <termui.KeyEvent>[];
        await tester.pumpWidget(
          _testApp(
            home: TerminalSurface(
              atlasController: atlasCtrl,
              service: service,
              selectionController: selectionController,
              buffer: buffer,
              copyOnSelect: false,
              reportKeyReleaseEvents: true,
              alignment: Alignment.topLeft,
              onInputEvent: (e) {
                if (e is termui.KeyEvent) keyEvents.add(e);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final atlas = atlasCtrl.atlas!;
        final topLeft = tester.getTopLeft(
          find.descendant(
            of: find.byType(TerminalSurface),
            matching: find.byType(CustomPaint),
          ),
        );
        Offset cellCenter(double col) =>
            topLeft + Offset(atlas.cellWidth * col, atlas.cellHeight * 0.5);

        final shortcuts = <List<LogicalKeyboardKey>>[
          [
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.shiftLeft,
            LogicalKeyboardKey.keyC,
          ],
          [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyC],
          [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.insert],
        ];
        for (final chord in shortcuts) {
          service.clipboardText = null;
          keyEvents.clear();

          final drag = await tester.startGesture(
            cellCenter(0.5),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await drag.moveTo(cellCenter(6.5));
          await tester.pump();
          await drag.up();
          await tester.pump();
          expect(selectionController.hasSelection, isTrue);

          for (final k in chord) {
            await tester.sendKeyDownEvent(k);
          }
          await tester.pump();
          await tester.sendKeyRepeatEvent(chord.last);
          await tester.pump();
          for (final k in chord.reversed) {
            await tester.sendKeyUpEvent(k);
          }
          await tester.pump();

          expect(service.clipboardText, equals('Copy Me'));
          expect(selectionController.hasSelection, isFalse);
          expect(
            keyEvents,
            isEmpty,
            reason: 'Expected held $chord repeat not to leak KeyEvents',
          );
        }
      },
    );

    testWidgets(
      'copying via keyboard shortcut while mouse press is held over a hyperlink does not open the link on release',
      (tester) async {
        final buffer = termui.Buffer(40, 4)
          ..writeString(0, 0, 'https://example.com/docs', const termui.Style());
        final atlasCtrl = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Cascadia Mono',
        );
        addTearDown(atlasCtrl.dispose);
        await tester.runAsync(atlasCtrl.ensureInitialized);

        await tester.pumpWidget(
          _testApp(
            home: TerminalSurface(
              atlasController: atlasCtrl,
              service: service,
              selectionController: selectionController,
              buffer: buffer,
              copyOnSelect: false,
              alignment: Alignment.topLeft,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final atlas = atlasCtrl.atlas!;
        final topLeft = tester.getTopLeft(
          find.descendant(
            of: find.byType(TerminalSurface),
            matching: find.byType(CustomPaint),
          ),
        );
        final wordHit =
            topLeft + Offset(atlas.cellWidth * 9.5, atlas.cellHeight * 0.5);

        // First click of double-click on 'example' inside the URL.
        final tap1 = await tester.startGesture(
          wordHit,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 20));
        await tap1.up();
        await tester.pump(const Duration(milliseconds: 40));

        // Second click held down -> selects 'example' while mouse button stays pressed.
        final tap2 = await tester.startGesture(
          wordHit,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 20));
        expect(selectionController.hasSelection, isTrue);
        expect(selectionController.extractText(buffer), equals('example'));

        // Copy via Cmd+C while mouse button is still held, then release mouse before releasing Cmd.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
        await tester.pump();

        expect(service.clipboardText, equals('example'));
        expect(selectionController.hasSelection, isFalse);

        await tap2.up();
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();

        expect(service.openedUrl, isNull);
      },
    );

    testWidgets(
      'resets selection mode on clearSelection and clears stuck Alt modifier after window lifecycle blur',
      (tester) async {
        final buffer = termui.Buffer(20, 4)
          ..writeString(0, 0, 'AAAA BBBB', const termui.Style())
          ..writeString(0, 1, 'CCCC DDDD', const termui.Style());
        final atlasCtrl = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Cascadia Mono',
        );
        addTearDown(atlasCtrl.dispose);
        await tester.runAsync(atlasCtrl.ensureInitialized);

        await tester.pumpWidget(
          _testApp(
            home: TerminalSurface(
              atlasController: atlasCtrl,
              service: service,
              selectionController: selectionController,
              buffer: buffer,
              alignment: Alignment.topLeft,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final atlas = atlasCtrl.atlas!;
        final topLeft = tester.getTopLeft(
          find.descendant(
            of: find.byType(TerminalSurface),
            matching: find.byType(CustomPaint),
          ),
        );
        Offset cell(double col, double row) =>
            topLeft + Offset(atlas.cellWidth * col, atlas.cellHeight * row);

        // 1. Alt+drag box selection clears back to SelectionMode.stream after copy/clear.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        final boxDrag = await tester.startGesture(
          cell(0.5, 0.5),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await boxDrag.moveTo(cell(2.5, 1.5));
        await tester.pump();
        expect(selectionController.mode, equals(SelectionMode.block));
        await boxDrag.up();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        expect(selectionController.hasSelection, isFalse);
        expect(selectionController.mode, equals(SelectionMode.stream));

        // 2. Simulate Alt+Tab window switch: AltDown arrives, then window blurs & resumes without AltUp.
        addTearDown(() async {
          if (HardwareKeyboard.instance.isAltPressed) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
          }
        });
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        // Subsequent drag without pressing Alt must perform stream selection, not stuck block selection.
        service.clipboardText = null;
        final streamDrag = await tester.startGesture(
          cell(5.5, 0.5),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await streamDrag.moveTo(cell(3.5, 1.5));
        await tester.pump();
        expect(selectionController.mode, equals(SelectionMode.stream));
        await streamDrag.up();
        await tester.pump();
        expect(service.clipboardText, equals('BBBB\nCCCC'));
      },
    );

    testWidgets(
      'stationary click during streaming output does not select/copy and standalone edge drag injects no wheel events',
      (WidgetTester tester) async {
        final service = FakeTerminalService();
        final selectionController = TerminalSelectionController();
        final notifier = ChangeNotifier();
        final atlasCtrl = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Cascadia Mono',
        );
        addTearDown(() {
          selectionController.dispose();
          notifier.dispose();
          atlasCtrl.dispose();
        });
        await tester.runAsync(atlasCtrl.ensureInitialized);

        final buf = termui.Buffer.blank(30, 8)
          ..writeString(0, 0, 'Log line 0', const termui.Style())
          ..writeString(0, 1, 'Log line 1', const termui.Style())
          ..writeString(0, 2, 'Log line 2', const termui.Style())
          ..writeString(0, 3, 'Log line 3', const termui.Style());
        var topVirtual = 10;
        final injectedEvents = <termui.InputEvent>[];

        await tester.pumpWidget(
          _testApp(
            home: SizedBox(
              width: 400,
              height: 240,
              child: TerminalSurface(
                atlasController: atlasCtrl,
                bufferProvider: () => buf,
                bufferListenable: notifier,
                topVirtualRowProvider: () => topVirtual,
                selectionController: selectionController,
                service: service,
                alignment: Alignment.topLeft,
                onInputEvent: injectedEvents.add,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final surfaceState = tester.state<TerminalSurfaceState>(
          find.byType(TerminalSurface),
        );
        final atlas = atlasCtrl.atlas!;
        final topLeft = tester.getTopLeft(
          find.descendant(
            of: find.byType(TerminalSurface),
            matching: find.byType(CustomPaint),
          ),
        );
        Offset cell(double col, double row) =>
            topLeft + Offset(atlas.cellWidth * col, atlas.cellHeight * row);

        // H2: Stationary focus click while PTY output advances topVirtualRow must NOT select or copy.
        final focusTap = await tester.startGesture(
          cell(2.5, 2.5),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        topVirtual += 3;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        notifier.notifyListeners();
        await tester.pump();
        await focusTap.up();
        await tester.pump();
        expect(surfaceState.debugGestureState.name, equals('idle'));
        expect(service.clipboardText, isNull);

        // H1: Standalone TerminalSurface (no scrollback callback) dragging past top edge must NOT inject wheelUp.
        injectedEvents.clear();
        final edgeDrag = await tester.startGesture(
          cell(2.5, 2.5),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await edgeDrag.moveTo(cell(2.5, -2.0));
        await tester.pump(const Duration(milliseconds: 160));
        await edgeDrag.up();
        await tester.pump();
        expect(
          injectedEvents.whereType<termui.MouseEvent>().where(
            (e) => e.button == termui.MouseButton.wheelUp,
          ),
          isEmpty,
        );

        // L3: With activePtySize: (30, 4) < buf.height (8) and onSelectionAutoScroll wired,
        // dragging into the dimmed bottom margin (rawRow = 6) keeps auto-scrolling past tick 1.
        final scrollDeltas = <int>[];
        await tester.pumpWidget(
          _testApp(
            home: SizedBox(
              width: 400,
              height: 240,
              child: TerminalSurface(
                atlasController: atlasCtrl,
                bufferProvider: () => buf,
                bufferListenable: notifier,
                activePtySize: const (30, 4),
                topVirtualRowProvider: () => topVirtual,
                onSelectionAutoScroll: (delta) {
                  scrollDeltas.add(delta);
                  topVirtual -= delta;
                  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
                  notifier.notifyListeners();
                },
                selectionController: selectionController,
                service: service,
                alignment: Alignment.topLeft,
                onInputEvent: injectedEvents.add,
              ),
            ),
          ),
        );
        await tester.pump();

        final marginDrag = await tester.startGesture(
          cell(2.5, 1.5),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await marginDrag.moveTo(cell(2.5, 6.5));
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 55));
        }
        await marginDrag.up();
        await tester.pump();
        expect(scrollDeltas.length, greaterThanOrEqualTo(3));
        expect(scrollDeltas.every((d) => d < 0), isTrue);
      },
    );

    testWidgets(
      'cleared Alt latch survives mounting a fresh TerminalSurface and macOS right-drag ignores active left selection',
      (WidgetTester tester) async {
        final service = FakeTerminalService();
        final selectionController = TerminalSelectionController();
        final atlasCtrl = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Cascadia Mono',
        );
        addTearDown(selectionController.dispose);
        addTearDown(atlasCtrl.dispose);
        addTearDown(() async {
          debugDefaultTargetPlatformOverride = null;
          if (HardwareKeyboard.instance.isAltPressed) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
          }
        });
        await tester.runAsync(atlasCtrl.ensureInitialized);

        final buf = termui.Buffer.blank(30, 6)
          ..writeString(0, 0, 'AAAA BBBB', const termui.Style())
          ..writeString(0, 1, 'CCCC DDDD', const termui.Style());

        Widget buildPane(String keyId) => _testApp(
          home: SizedBox(
            width: 400,
            height: 200,
            child: TerminalSurface(
              key: ValueKey(keyId),
              atlasController: atlasCtrl,
              buffer: buf,
              selectionController: selectionController,
              service: service,
              alignment: Alignment.topLeft,
            ),
          ),
        );

        await tester.pumpWidget(buildPane('tab-1'));
        await tester.pumpAndSettle();

        // M1: AltDown + lifecycle blur/resume on tab-1, then switch to freshly mounted tab-2.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(buildPane('tab-2'));
        await tester.pumpAndSettle();

        final atlas = atlasCtrl.atlas!;
        final topLeft = tester.getTopLeft(
          find.descendant(
            of: find.byType(TerminalSurface),
            matching: find.byType(CustomPaint),
          ),
        );
        Offset cell(double col, double row) =>
            topLeft + Offset(atlas.cellWidth * col, atlas.cellHeight * row);

        final tab2Drag = await tester.startGesture(
          cell(5.5, 0.5),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await tab2Drag.moveTo(cell(3.5, 1.5));
        await tester.pump();
        expect(selectionController.mode, equals(SelectionMode.stream));
        await tab2Drag.up();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();

        // L2: On macOS, secondary button pressed mid-primary-drag must NOT mutate primary selection.
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final leftDrag = await tester.startGesture(
          cell(1.5, 0.5),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await leftDrag.moveTo(cell(4.5, 0.5));
        await tester.pump();
        expect(selectionController.focus?.col, equals(4));

        tester.binding.handlePointerEvent(
          PointerMoveEvent(
            position: cell(8.5, 0.5),
            kind: PointerDeviceKind.mouse,
            buttons: kPrimaryMouseButton | kSecondaryMouseButton,
          ),
        );
        await tester.pump();
        expect(selectionController.focus?.col, equals(4));
        await leftDrag.up();
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      },
    );

    test('FlutterTerminalBackend DECSET mouse modes 9/1000/1002/1003 and RIS resets', () {
      final terminal = FlutterTerminal();
      addTearDown(terminal.dispose);
      final b = terminal.backend;
      expect(terminal.mouseTracking, isFalse);
      for (final m in const ['9', '1000', '1002', '1003']) {
        b.write('\x1b[?${m}h');
        expect(terminal.mouseTracking, isTrue);
        b.write('\x1b[?${m}l');
        expect(terminal.mouseTracking, isFalse);
      }
      b.write('\x1b[?1000;1002h');
      expect(terminal.mouseTracking, isTrue);
      b.write('\x1b[?1000l');
      expect(terminal.mouseTracking, isTrue);
      for (final reset in const ['\x1bc', '\x1b[!p']) {
        b.write('\x1b[?1003h');
        expect(terminal.mouseTracking, isTrue);
        b.write(reset);
        expect(terminal.mouseTracking, isFalse);
      }
    });
  });
}
