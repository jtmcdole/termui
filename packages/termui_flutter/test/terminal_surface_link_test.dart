import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/termui.dart' as termui;
import 'package:termui_flutter/termui_flutter.dart';

class _RecordingTerminalService implements TerminalService {
  final List<String> openedUrls = <String>[];

  @override
  Future<void> setClipboard(String text) async {}

  @override
  Future<String?> getClipboard() async => null;

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return true;
  }

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) async =>
      basename;
}

Widget _wrapSurface({
  required termui.Buffer? buffer,
  required TerminalService service,
  required GlyphAtlasController atlasController,
  Listenable? bufferListenable,
  VirtualLineLookup? linkLineLookup,
  void Function(termui.InputEvent)? onInputEvent,
  bool mouseTracking = false,
  bool autofocus = true,
  bool enableBuiltinLinkOpen = true,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 500,
        height: 200,
        child: TerminalSurface(
          atlasController: atlasController,
          buffer: buffer,
          bufferListenable: bufferListenable,
          linkLineLookup: linkLineLookup,
          service: service,
          onInputEvent: onInputEvent,
          mouseTracking: mouseTracking,
          autofocus: autofocus,
          enableBuiltinLinkOpen: enableBuiltinLinkOpen,
          fontSize: 14.0,
          alignment: Alignment.topLeft,
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSurface link hover and activation', () {
    testWidgets('Ctrl+Click and Cmd+Click open plain-text https URLs', (
      tester,
    ) async {
      final service = _RecordingTerminalService();
      final atlasController = GlyphAtlasController(fontSize: 14.0);
      addTearDown(atlasController.dispose);
      final buffer = termui.Buffer(45, 4);
      buffer.writeString(
        0,
        0,
        'See https://example.com/a?x=1 here',
        const termui.Style(),
      );

      await tester.pumpWidget(
        _wrapSurface(
          buffer: buffer,
          service: service,
          atlasController: atlasController,
        ),
      );
      await tester.pumpAndSettle();

      final cellW = atlasController.atlas!.cellWidth;
      final cellH = atlasController.atlas!.cellHeight;
      final origin = tester.getTopLeft(find.byType(CustomPaint).last);
      // Column 6 is inside "https://example.com/a?x=1".
      final linkPos = origin + Offset(cellW * 6.5, cellH * 0.5);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final ctrlClick = await tester.startGesture(
        linkPos,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await ctrlClick.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      final cmdClick = await tester.startGesture(
        linkPos,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await cmdClick.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(service.openedUrls, <String>[
        'https://example.com/a?x=1',
        'https://example.com/a?x=1',
      ]);
    });

    testWidgets(
      'macOS Ctrl+RightClick opens plain-text and OSC 8 URLs without leaking right-click to PTY',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final service = _RecordingTerminalService();
        final atlasController = GlyphAtlasController(fontSize: 14.0);
        addTearDown(atlasController.dispose);
        final ptyEvents = <termui.InputEvent>[];
        final buffer = termui.Buffer(45, 4);
        buffer.writeString(
          0,
          0,
          'Visit https://example.com/mac now',
          const termui.Style(),
        );
        buffer.writeString(0, 1, 'Docs', const termui.Style());
        for (var x = 0; x < 4; x++) {
          buffer.setUri(x, 1, 'mailto:team@example.com');
        }

        await tester.pumpWidget(
          _wrapSurface(
            buffer: buffer,
            service: service,
            atlasController: atlasController,
            mouseTracking: true,
            onInputEvent: ptyEvents.add,
          ),
        );
        await tester.pumpAndSettle();

        final cellW = atlasController.atlas!.cellWidth;
        final cellH = atlasController.atlas!.cellHeight;
        final origin = tester.getTopLeft(find.byType(CustomPaint).last);

        Future<void> ctrlRightClick(Offset pos) async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          final g = await tester.startGesture(
            pos,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pump();
          await g.up();
          await tester.pump();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
        }

        await ctrlRightClick(origin + Offset(cellW * 10.5, cellH * 0.5));
        await ctrlRightClick(origin + Offset(cellW * 1.5, cellH * 1.5));

        expect(service.openedUrls, <String>[
          'https://example.com/mac',
          'mailto:team@example.com',
        ]);
        expect(
          ptyEvents.whereType<termui.MouseEvent>().where(
            (e) =>
                e.button == termui.MouseButton.right &&
                (e.type == termui.MouseEventType.press ||
                    e.type == termui.MouseEventType.release),
          ),
          isEmpty,
        );
      },
    );

    testWidgets(
      'unfocused pane updates click cursor on stationary Ctrl press and clears on pointer exit',
      (tester) async {
        final service = _RecordingTerminalService();
        final atlasController = GlyphAtlasController(fontSize: 14.0);
        addTearDown(atlasController.dispose);
        final buffer = termui.Buffer(40, 4);
        buffer.writeString(
          0,
          0,
          'Open https://example.com/cursor',
          const termui.Style(),
        );

        await tester.pumpWidget(
          _wrapSurface(
            buffer: buffer,
            service: service,
            atlasController: atlasController,
            autofocus: false,
          ),
        );
        await tester.pumpAndSettle();

        final cellW = atlasController.atlas!.cellWidth;
        final cellH = atlasController.atlas!.cellHeight;
        final origin = tester.getTopLeft(find.byType(CustomPaint).last);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: origin - const Offset(10, 10));
        await tester.pump();
        await mouse.moveTo(origin + Offset(cellW * 8.5, cellH * 0.5));
        await tester.pump();

        MouseRegion region() =>
            tester.widget<MouseRegion>(find.byType(MouseRegion).last);
        expect(region().cursor, equals(SystemMouseCursors.basic));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(region().cursor, equals(SystemMouseCursors.click));

        await mouse.moveTo(origin + const Offset(600, 10));
        await tester.pump();
        expect(region().cursor, equals(SystemMouseCursors.basic));

        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      },
    );

    testWidgets(
      'soft-wrapped multi-row plain-text URL via linkLineLookup opens full URL from both rows',
      (tester) async {
        final service = _RecordingTerminalService();
        final atlasController = GlyphAtlasController(fontSize: 14.0);
        addTearDown(atlasController.dispose);
        final buffer = termui.Buffer(20, 4);
        buffer.writeString(0, 0, 'See https://example.', const termui.Style());
        buffer.writeString(0, 1, 'com/path/to/page ok', const termui.Style());

        VirtualLineSlice? lookup(int vRow) {
          if (vRow < 0 || vRow >= buffer.height) return null;
          final start = vRow * buffer.width;
          return (
            isWrapped: vRow == 1,
            characters: buffer.characters.sublist(start, start + buffer.width),
            uris: null,
          );
        }

        await tester.pumpWidget(
          _wrapSurface(
            buffer: buffer,
            linkLineLookup: lookup,
            service: service,
            atlasController: atlasController,
          ),
        );
        await tester.pumpAndSettle();

        final cellW = atlasController.atlas!.cellWidth;
        final cellH = atlasController.atlas!.cellHeight;
        final origin = tester.getTopLeft(find.byType(CustomPaint).last);

        Future<void> ctrlClick(Offset pos) async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          final g = await tester.startGesture(
            pos,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await g.up();
          await tester.pump();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
        }

        // Click row 0 ("https://example.") and row 1 ("com/path/to/page").
        await ctrlClick(origin + Offset(cellW * 10.5, cellH * 0.5));
        await ctrlClick(origin + Offset(cellW * 4.5, cellH * 1.5));

        expect(service.openedUrls, <String>[
          'https://example.com/path/to/page',
          'https://example.com/path/to/page',
        ]);
      },
    );

    testWidgets(
      'resting hover updates cursor on buffer update and clears on buffer clear without mouse movement',
      (tester) async {
        final service = _RecordingTerminalService();
        final atlasController = GlyphAtlasController(fontSize: 14.0);
        addTearDown(atlasController.dispose);
        final buffer = termui.Buffer(40, 4);
        buffer.writeString(
          0,
          0,
          'Plain text without any url',
          const termui.Style(),
        );
        final bufferNotifier = ValueNotifier<int>(0);
        addTearDown(bufferNotifier.dispose);

        await tester.pumpWidget(
          _wrapSurface(
            buffer: buffer,
            bufferListenable: bufferNotifier,
            service: service,
            atlasController: atlasController,
          ),
        );
        await tester.pumpAndSettle();

        final cellW = atlasController.atlas!.cellWidth;
        final cellH = atlasController.atlas!.cellHeight;
        final origin = tester.getTopLeft(find.byType(CustomPaint).last);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: origin - const Offset(10, 10));
        await tester.pump();
        await mouse.moveTo(origin + Offset(cellW * 8.5, cellH * 0.5));
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        MouseRegion region() =>
            tester.widget<MouseRegion>(find.byType(MouseRegion).last);
        expect(region().cursor, equals(SystemMouseCursors.basic));

        // Mutate buffer in place so a URL appears under the resting cursor.
        buffer.clear();
        buffer.writeString(
          0,
          0,
          'See https://example.com/live',
          const termui.Style(),
        );
        bufferNotifier.value++;
        await tester.pump();
        expect(region().cursor, equals(SystemMouseCursors.click));

        // Clear buffer in place without moving the mouse.
        buffer.clear();
        bufferNotifier.value++;
        await tester.pump();
        expect(region().cursor, equals(SystemMouseCursors.basic));

        // Restore URL via listenable, then clear via widget buffer: null.
        buffer.writeString(
          0,
          0,
          'See https://example.com/live',
          const termui.Style(),
        );
        bufferNotifier.value++;
        await tester.pump();
        expect(region().cursor, equals(SystemMouseCursors.click));

        await tester.pumpWidget(
          _wrapSurface(
            buffer: null,
            bufferListenable: bufferNotifier,
            service: service,
            atlasController: atlasController,
          ),
        );
        await tester.pump();
        expect(region().cursor, equals(SystemMouseCursors.basic));

        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      },
    );

    testWidgets(
      'plain right-click, non-link Ctrl+RightClick, and Linux Ctrl+RightClick forward to PTY',
      (tester) async {
        final service = _RecordingTerminalService();
        final atlasController = GlyphAtlasController(fontSize: 14.0);
        addTearDown(atlasController.dispose);
        final ptyEvents = <termui.InputEvent>[];
        final buffer = termui.Buffer(45, 4);
        buffer.writeString(
          0,
          0,
          'Visit https://example.com/mac plain',
          const termui.Style(),
        );

        await tester.pumpWidget(
          _wrapSurface(
            buffer: buffer,
            service: service,
            atlasController: atlasController,
            mouseTracking: true,
            onInputEvent: ptyEvents.add,
          ),
        );
        await tester.pumpAndSettle();

        final cellW = atlasController.atlas!.cellWidth;
        final cellH = atlasController.atlas!.cellHeight;
        final origin = tester.getTopLeft(find.byType(CustomPaint).last);
        final linkPos = origin + Offset(cellW * 10.5, cellH * 0.5);
        final plainPos = origin + Offset(cellW * 32.5, cellH * 0.5);

        Future<void> rightClick(Offset pos, {bool withCtrl = false}) async {
          if (withCtrl) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.pump();
          }
          final g = await tester.startGesture(
            pos,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pump();
          await g.up();
          await tester.pump();
          if (withCtrl) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await tester.pump();
          }
        }

        List<termui.MouseEvent> rightPressReleases() => ptyEvents
            .whereType<termui.MouseEvent>()
            .where(
              (e) =>
                  e.button == termui.MouseButton.right &&
                  (e.type == termui.MouseEventType.press ||
                      e.type == termui.MouseEventType.release),
            )
            .toList();

        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        // 1. Plain right-click over a link forwards press+release to PTY.
        await rightClick(linkPos);
        expect(rightPressReleases(), hasLength(2));

        // 2. Non-link Ctrl+RightClick forwards press+release to PTY.
        ptyEvents.clear();
        await rightClick(plainPos, withCtrl: true);
        expect(rightPressReleases(), hasLength(2));

        // 3. Linux Ctrl+RightClick on a link forwards press+release to PTY and does not open URL.
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        ptyEvents.clear();
        await rightClick(linkPos, withCtrl: true);
        expect(rightPressReleases(), hasLength(2));
        expect(service.openedUrls, isEmpty);
      },
    );
  });
}
